#include "HoloscapeNativePTY.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/poll.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

enum {
    HOLOSCAPE_HANDSHAKE_TIMEOUT_MILLISECONDS = 5000,
    HOLOSCAPE_CLEANUP_TIMEOUT_MILLISECONDS = 1000,
};

static int64_t monotonic_milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int deadline_after_milliseconds(int timeout_milliseconds, int64_t *deadline) {
    int64_t now = monotonic_milliseconds();
    if (now < 0) {
        return errno;
    }
    *deadline = now + timeout_milliseconds;
    return 0;
}

static int wait_until_ready(int descriptor, short events, int64_t deadline) {
    for (;;) {
        int64_t now = monotonic_milliseconds();
        if (now < 0) {
            return errno;
        }
        if (now >= deadline) {
            return ETIMEDOUT;
        }
        int64_t remaining = deadline - now;
        int timeout = remaining > INT_MAX ? INT_MAX : (int)remaining;
        struct pollfd poll_descriptor = {
            .fd = descriptor,
            .events = events,
            .revents = 0,
        };
        int ready = poll(&poll_descriptor, 1, timeout);
        if (ready < 0 && errno == EINTR) {
            continue;
        }
        if (ready < 0) {
            return errno;
        }
        if (ready == 0) {
            return ETIMEDOUT;
        }
        if ((poll_descriptor.revents & POLLNVAL) != 0) {
            return EBADF;
        }
        if ((poll_descriptor.revents & (events | POLLHUP | POLLERR)) != 0) {
            return 0;
        }
    }
}

static int configure_handshake_writer(int descriptor) {
    if (fcntl(descriptor, F_SETNOSIGPIPE, 1) != 0) {
        return errno;
    }
    return 0;
}

static int write_exact_until(int descriptor, const void *buffer, size_t count, int64_t deadline) {
    const unsigned char *cursor = buffer;
    size_t remaining = count;
    while (remaining > 0) {
        int wait_error = wait_until_ready(descriptor, POLLOUT, deadline);
        if (wait_error != 0) {
            return wait_error;
        }
        ssize_t written = write(descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return written < 0 ? errno : EPIPE;
        }
        cursor += written;
        remaining -= (size_t)written;
    }
    return 0;
}

static int read_exact_until(int descriptor, void *buffer, size_t count, int64_t deadline) {
    unsigned char *cursor = buffer;
    size_t remaining = count;
    while (remaining > 0) {
        int wait_error = wait_until_ready(descriptor, POLLIN, deadline);
        if (wait_error != 0) {
            return wait_error;
        }
        ssize_t received = read(descriptor, cursor, remaining);
        if (received < 0 && errno == EINTR) {
            continue;
        }
        if (received <= 0) {
            return received < 0 ? errno : EPIPE;
        }
        cursor += received;
        remaining -= (size_t)received;
    }
    return 0;
}

static void report_child_error_and_exit(int error_fd, int error_code) {
    int saved_errno = error_code;
    int64_t deadline;
    if (deadline_after_milliseconds(HOLOSCAPE_HANDSHAKE_TIMEOUT_MILLISECONDS, &deadline) == 0) {
        (void)write_exact_until(error_fd, &saved_errno, sizeof(saved_errno), deadline);
    }
    _exit(127);
}

static int move_descriptor_above_stdio(int *descriptor) {
    if (*descriptor >= STDERR_FILENO + 1) {
        if (fcntl(*descriptor, F_SETFD, FD_CLOEXEC) == 0) {
            return 0;
        }
        return errno;
    }

    int duplicated = fcntl(*descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    if (duplicated < 0) {
        return errno;
    }
    close(*descriptor);
    *descriptor = duplicated;
    return 0;
}

static int prepare_child_error_descriptor(int *error_fd, long descriptor_limit) {
    const int child_error_fd = STDERR_FILENO + 1;
    if (*error_fd != child_error_fd) {
        if (dup2(*error_fd, child_error_fd) < 0) {
            return errno;
        }
        close(*error_fd);
        *error_fd = child_error_fd;
    }
    if (fcntl(child_error_fd, F_SETFD, FD_CLOEXEC) != 0) {
        return errno;
    }
    for (int descriptor = child_error_fd + 1; descriptor < descriptor_limit; descriptor++) {
        close(descriptor);
    }
    return 0;
}

typedef int (*holoscape_sleep_function)(
    const struct timespec *requested,
    struct timespec *remaining,
    void *context
);

static int system_nanosleep(
    const struct timespec *requested,
    struct timespec *remaining,
    void *context
) {
    (void)context;
    return nanosleep(requested, remaining);
}

static int wait_for_child_bounded_with_sleep(
    pid_t pid,
    int timeout_milliseconds,
    holoscape_sleep_function sleep_function,
    void *sleep_context
) {
    int status;
    int64_t deadline;
    int deadline_error = deadline_after_milliseconds(timeout_milliseconds, &deadline);
    if (deadline_error != 0) {
        return deadline_error;
    }
    for (;;) {
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid) {
            return 0;
        }
        if (result < 0 && errno != EINTR) {
            return errno;
        }
        int64_t now = monotonic_milliseconds();
        if (now < 0) {
            return errno;
        }
        if (now >= deadline) {
            return ETIMEDOUT;
        }
        const struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000};
        struct timespec remaining = pause;
        if (sleep_function(&pause, &remaining, sleep_context) != 0 && errno != EINTR) {
            return errno;
        }
    }
}

static int wait_for_child_bounded(pid_t pid, int timeout_milliseconds) {
    return wait_for_child_bounded_with_sleep(
        pid,
        timeout_milliseconds,
        system_nanosleep,
        NULL
    );
}

static int kill_and_wait(pid_t pid, pid_t process_group_id) {
    if (kill(-process_group_id, SIGKILL) != 0 && errno != ESRCH) {
        return errno;
    }
    return wait_for_child_bounded(pid, HOLOSCAPE_CLEANUP_TIMEOUT_MILLISECONDS);
}

int holoscape_spawn_pty(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    uint16_t rows,
    uint16_t columns,
    pid_t *child_pid,
    pid_t *process_group_id,
    int *master_fd,
    int *cleanup_pending
) {
    *child_pid = 0;
    *process_group_id = 0;
    *master_fd = -1;
    *cleanup_pending = 0;
    int error_pipe[2];
    if (pipe(error_pipe) != 0) {
        return errno;
    }
    int launch_pipe[2];
    if (pipe(launch_pipe) != 0) {
        int error_code = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        return error_code;
    }

    int descriptor_error = move_descriptor_above_stdio(&error_pipe[0]);
    if (descriptor_error == 0) {
        descriptor_error = move_descriptor_above_stdio(&error_pipe[1]);
    }
    if (descriptor_error == 0) {
        descriptor_error = move_descriptor_above_stdio(&launch_pipe[0]);
    }
    if (descriptor_error == 0) {
        descriptor_error = move_descriptor_above_stdio(&launch_pipe[1]);
    }
    if (descriptor_error == 0) {
        descriptor_error = configure_handshake_writer(error_pipe[1]);
    }
    if (descriptor_error == 0) {
        descriptor_error = configure_handshake_writer(launch_pipe[1]);
    }
    if (descriptor_error != 0) {
        close(error_pipe[0]);
        close(error_pipe[1]);
        close(launch_pipe[0]);
        close(launch_pipe[1]);
        return descriptor_error;
    }

    errno = 0;
    long descriptor_limit = sysconf(_SC_OPEN_MAX);
    if (descriptor_limit < 0 || descriptor_limit > INT_MAX) {
        int error_code = errno != 0 ? errno : EOVERFLOW;
        close(error_pipe[0]);
        close(error_pipe[1]);
        close(launch_pipe[0]);
        close(launch_pipe[1]);
        return error_code;
    }

    struct winsize size = {
        .ws_row = rows,
        .ws_col = columns,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    int spawned_master = -1;
    pid_t pid = forkpty(&spawned_master, NULL, NULL, &size);
    if (pid < 0) {
        int error_code = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        close(launch_pipe[0]);
        close(launch_pipe[1]);
        return error_code;
    }

    if (pid == 0) {
        close(error_pipe[0]);
        close(launch_pipe[1]);

        int child_ready = 0;
        int64_t handshake_deadline;
        int handshake_error = deadline_after_milliseconds(
            HOLOSCAPE_HANDSHAKE_TIMEOUT_MILLISECONDS,
            &handshake_deadline
        );
        if (handshake_error == 0) {
            handshake_error = write_exact_until(
                error_pipe[1],
                &child_ready,
                sizeof(child_ready),
                handshake_deadline
            );
        }
        if (handshake_error != 0) {
            _exit(127);
        }
        unsigned char launch_permission = 0;
        handshake_error = deadline_after_milliseconds(
            HOLOSCAPE_HANDSHAKE_TIMEOUT_MILLISECONDS,
            &handshake_deadline
        );
        if (handshake_error == 0) {
            handshake_error = read_exact_until(
                launch_pipe[0],
                &launch_permission,
                sizeof(launch_permission),
                handshake_deadline
            );
        }
        close(launch_pipe[0]);
        if (handshake_error != 0) {
            report_child_error_and_exit(error_pipe[1], handshake_error);
        }
        if (launch_permission != 1) {
            report_child_error_and_exit(error_pipe[1], EPROTO);
        }

        int child_descriptor_error = prepare_child_error_descriptor(&error_pipe[1], descriptor_limit);
        if (child_descriptor_error != 0) {
            report_child_error_and_exit(error_pipe[1], child_descriptor_error);
        }
        if (working_directory != NULL && chdir(working_directory) != 0) {
            report_child_error_and_exit(error_pipe[1], errno);
        }
        execve(executable, argv, envp);
        report_child_error_and_exit(error_pipe[1], errno);
    }

    close(error_pipe[1]);
    close(launch_pipe[0]);
    *child_pid = pid;
    // forkpty establishes the child as the new session and process-group
    // leader before its child-side continuation runs.
    *process_group_id = pid;
    *master_fd = spawned_master;

    int child_ready = -1;
    int64_t handshake_deadline;
    int handshake_error = deadline_after_milliseconds(
        HOLOSCAPE_HANDSHAKE_TIMEOUT_MILLISECONDS,
        &handshake_deadline
    );
    if (handshake_error == 0) {
        handshake_error = read_exact_until(
            error_pipe[0],
            &child_ready,
            sizeof(child_ready),
            handshake_deadline
        );
    }
    if (handshake_error != 0 || child_ready != 0) {
        close(error_pipe[0]);
        close(launch_pipe[1]);
        int signal_error = kill(pid, SIGKILL) == 0 || errno == ESRCH ? 0 : errno;
        int wait_error = signal_error == 0
            ? wait_for_child_bounded(pid, HOLOSCAPE_CLEANUP_TIMEOUT_MILLISECONDS)
            : 0;
        if (signal_error != 0) {
            *cleanup_pending = 1;
            return signal_error;
        }
        if (wait_error != 0) {
            *cleanup_pending = 1;
            return wait_error;
        }
        return handshake_error != 0 ? handshake_error : EPROTO;
    }

    pid_t observed_process_group_id = getpgid(pid);
    if (observed_process_group_id > 0) {
        *process_group_id = observed_process_group_id;
    }
    if (observed_process_group_id != pid) {
        int identity_error = observed_process_group_id < 0 ? errno : EPROTO;
        close(error_pipe[0]);
        close(launch_pipe[1]);
        int signal_error = kill(pid, SIGKILL) == 0 || errno == ESRCH ? 0 : errno;
        int wait_error = signal_error == 0
            ? wait_for_child_bounded(pid, HOLOSCAPE_CLEANUP_TIMEOUT_MILLISECONDS)
            : 0;
        if (signal_error != 0 || wait_error != 0) {
            *cleanup_pending = 1;
        }
        return signal_error != 0 ? signal_error : (wait_error != 0 ? wait_error : identity_error);
    }

    if (fcntl(spawned_master, F_SETFD, FD_CLOEXEC) != 0) {
        int descriptor_setup_error = errno;
        close(error_pipe[0]);
        close(launch_pipe[1]);
        int cleanup_error = kill_and_wait(pid, observed_process_group_id);
        if (cleanup_error != 0) {
            *cleanup_pending = 1;
        }
        return cleanup_error != 0 ? cleanup_error : descriptor_setup_error;
    }

    *child_pid = pid;
    *process_group_id = observed_process_group_id;
    *master_fd = spawned_master;

    unsigned char launch_permission = 1;
    int release_error = deadline_after_milliseconds(
        HOLOSCAPE_HANDSHAKE_TIMEOUT_MILLISECONDS,
        &handshake_deadline
    );
    if (release_error == 0) {
        release_error = write_exact_until(
            launch_pipe[1],
            &launch_permission,
            sizeof(launch_permission),
            handshake_deadline
        );
    }
    close(launch_pipe[1]);
    if (release_error != 0) {
        close(error_pipe[0]);
        int cleanup_error = kill_and_wait(pid, observed_process_group_id);
        if (cleanup_error != 0) {
            *cleanup_pending = 1;
        }
        return cleanup_error != 0 ? cleanup_error : release_error;
    }

    int child_error = 0;
    size_t bytes_received = 0;
    int read_error = deadline_after_milliseconds(
        HOLOSCAPE_HANDSHAKE_TIMEOUT_MILLISECONDS,
        &handshake_deadline
    );
    while (read_error == 0 && bytes_received < sizeof(child_error)) {
        read_error = wait_until_ready(error_pipe[0], POLLIN, handshake_deadline);
        if (read_error != 0) {
            break;
        }
        ssize_t count = read(
            error_pipe[0],
            (unsigned char *)&child_error + bytes_received,
            sizeof(child_error) - bytes_received
        );
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0) {
            read_error = errno;
            break;
        }
        if (count == 0) {
            break;
        }
        bytes_received += (size_t)count;
    }
    close(error_pipe[0]);

    if (bytes_received > 0 || read_error != 0) {
        int wait_error = wait_for_child_bounded(pid, HOLOSCAPE_CLEANUP_TIMEOUT_MILLISECONDS);
        if (wait_error != 0) {
            *cleanup_pending = 1;
            return wait_error;
        }
        if (bytes_received != sizeof(child_error)) {
            return read_error != 0 ? read_error : EPROTO;
        }
        return child_error;
    }

    return 0;
}

int holoscape_get_foreground_process_group(
    int master_fd,
    pid_t session_id,
    pid_t *foreground_process_group_id
) {
    pid_t foreground = tcgetpgrp(master_fd);
    if (foreground < 0) {
        int foreground_error = errno;
        return foreground_error == ENOTTY || foreground_error == EIO
            ? ESRCH
            : foreground_error;
    }
    if (foreground == 0) {
        *foreground_process_group_id = 0;
        return 0;
    }
    int validation = holoscape_validate_process_group_session(foreground, session_id);
    if (validation < 0) {
        return -validation;
    }
    if (validation == 0) {
        return ESRCH;
    }
    *foreground_process_group_id = foreground;
    return 0;
}

typedef int (*holoscape_foreground_snapshot_function)(
    int master_fd,
    pid_t session_id,
    pid_t *foreground_process_group_id,
    void *context
);

typedef int (*holoscape_child_exit_observation_function)(
    pid_t child_pid,
    int *exit_observed,
    void *context
);

static int system_foreground_snapshot(
    int master_fd,
    pid_t session_id,
    pid_t *foreground_process_group_id,
    void *context
) {
    (void)context;
    return holoscape_get_foreground_process_group(
        master_fd,
        session_id,
        foreground_process_group_id
    );
}

static int system_child_exit_observation(
    pid_t child_pid,
    int *exit_observed,
    void *context
) {
    (void)context;
    siginfo_t information;
    memset(&information, 0, sizeof(information));
    if (waitid(P_PID, (id_t)child_pid, &information, WEXITED | WNOHANG | WNOWAIT) != 0) {
        return errno;
    }
    *exit_observed = information.si_pid == child_pid;
    return 0;
}

static int transient_exit_observation_error(int error_code) {
    return error_code == EAGAIN || error_code == EINTR;
}

static int capture_foreground_snapshot(
    int master_fd,
    pid_t session_id,
    pid_t *foreground_process_group_id,
    holoscape_foreground_snapshot_function foreground_snapshot,
    void *context
) {
    pid_t foreground = 0;
    int snapshot_error = foreground_snapshot(
        master_fd,
        session_id,
        &foreground,
        context
    );
    if (snapshot_error == 0 && foreground > 0) {
        *foreground_process_group_id = foreground;
        return 0;
    }
    // Foreground identity is an optimization, not exit authority. Process-group
    // churn may make this snapshot transiently unavailable; keep polling the
    // child with WNOWAIT so its PID/session identity stays reserved. Swift later
    // enumerates and kills every live same-session group before the sole reap.
    if (snapshot_error == ESRCH || transient_exit_observation_error(snapshot_error)) {
        return 0;
    }
    return snapshot_error;
}

static int observe_pty_exit_with_functions(
    pid_t child_pid,
    pid_t session_id,
    int master_fd,
    pid_t *foreground_process_group_id,
    holoscape_foreground_snapshot_function foreground_snapshot,
    holoscape_child_exit_observation_function child_exit_observation,
    void *context
) {
    *foreground_process_group_id = 0;
    for (;;) {
        int foreground_error = capture_foreground_snapshot(
            master_fd,
            session_id,
            foreground_process_group_id,
            foreground_snapshot,
            context
        );
        if (foreground_error != 0) {
            return foreground_error;
        }

        int exit_observed = 0;
        int observation_error = child_exit_observation(
            child_pid,
            &exit_observed,
            context
        );
        if (observation_error != 0 && !transient_exit_observation_error(observation_error)) {
            return observation_error;
        }
        if (observation_error == 0 && exit_observed) {
            foreground_error = capture_foreground_snapshot(
                master_fd,
                session_id,
                foreground_process_group_id,
                foreground_snapshot,
                context
            );
            if (foreground_error != 0) {
                return foreground_error;
            }
            return 0;
        }
        struct timespec pause = {.tv_sec = 0, .tv_nsec = 10000000};
        while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {
        }
    }
}

int holoscape_observe_pty_exit(
    pid_t child_pid,
    pid_t session_id,
    int master_fd,
    pid_t *foreground_process_group_id
) {
    return observe_pty_exit_with_functions(
        child_pid,
        session_id,
        master_fd,
        foreground_process_group_id,
        system_foreground_snapshot,
        system_child_exit_observation,
        NULL
    );
}

int holoscape_reap_pid(pid_t child_pid, int32_t *termination_status) {
    int status;
    // Return EINTR to the Swift cleanup owner. It owns the single monotonic
    // deadline and decides whether another sole-reap attempt is still allowed;
    // retrying here would invisibly extend that deadline.
    pid_t result = waitpid(child_pid, &status, 0);
    if (result < 0) {
        return errno;
    }
    if (WIFEXITED(status)) {
        *termination_status = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        *termination_status = WTERMSIG(status);
    } else {
        *termination_status = status;
    }
    return 0;
}

int holoscape_process_exit_observed(pid_t child_pid) {
    siginfo_t information;
    memset(&information, 0, sizeof(information));
    for (;;) {
        if (waitid(P_PID, (id_t)child_pid, &information, WEXITED | WNOHANG | WNOWAIT) == 0) {
            return information.si_pid == child_pid ? 1 : 0;
        }
        if (errno != EINTR) {
            return -errno;
        }
    }
}

int holoscape_process_group_has_live_member(
    pid_t process_group_id,
    pid_t excluded_process_id
) {
    int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, process_group_id};
    for (int attempt = 0; attempt < 3; attempt++) {
        size_t byte_count = 0;
        if (sysctl(query, 4, NULL, &byte_count, NULL, 0) != 0) {
            return -errno;
        }
        if (byte_count == 0) {
            return 0;
        }
        struct kinfo_proc *processes = malloc(byte_count);
        if (processes == NULL) {
            return -ENOMEM;
        }
        size_t populated_byte_count = byte_count;
        if (sysctl(query, 4, processes, &populated_byte_count, NULL, 0) != 0) {
            int query_error = errno;
            free(processes);
            if (query_error == ENOMEM) {
                continue;
            }
            return -query_error;
        }
        size_t process_count = populated_byte_count / sizeof(struct kinfo_proc);
        int has_live_member = 0;
        for (size_t index = 0; index < process_count; index++) {
            if (processes[index].kp_proc.p_pid != excluded_process_id
                && processes[index].kp_proc.p_stat != SZOMB) {
                has_live_member = 1;
                break;
            }
        }
        free(processes);
        return has_live_member;
    }
    return -ENOMEM;
}

typedef pid_t (*session_lookup_function)(pid_t process_id);

static int inspect_process_snapshot_session(
    const struct kinfo_proc *processes,
    size_t process_count,
    pid_t session_id,
    int *has_live_member,
    int *has_live_session_member,
    session_lookup_function session_lookup
) {
    int observed_live_member = 0;
    int observed_live_session_member = 0;
    int saw_disappearing_member = 0;
    for (size_t index = 0; index < process_count; index++) {
        pid_t member_pid = processes[index].kp_proc.p_pid;
        if (processes[index].kp_proc.p_stat == SZOMB) {
            continue;
        }
        pid_t observed_session = session_lookup(member_pid);
        if (observed_session < 0) {
            if (errno == ESRCH) {
                saw_disappearing_member = 1;
                continue;
            }
            return errno;
        }
        observed_live_member = 1;
        if (observed_session == session_id) {
            observed_live_session_member = 1;
        }
    }
    if (saw_disappearing_member && !observed_live_session_member) {
        return EAGAIN;
    }
    *has_live_member = observed_live_member;
    *has_live_session_member = observed_live_session_member;
    return 0;
}

static int inspect_process_group_session_with_lookup(
    pid_t process_group_id,
    pid_t session_id,
    int *has_live_member,
    int *has_live_session_member,
    session_lookup_function session_lookup
) {
    int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, process_group_id};
    for (int attempt = 0; attempt < 3; attempt++) {
        size_t byte_count = 0;
        if (sysctl(query, 4, NULL, &byte_count, NULL, 0) != 0) {
            return errno;
        }
        if (byte_count == 0) {
            *has_live_member = 0;
            *has_live_session_member = 0;
            return 0;
        }
        struct kinfo_proc *processes = malloc(byte_count);
        if (processes == NULL) {
            return ENOMEM;
        }
        size_t populated_byte_count = byte_count;
        if (sysctl(query, 4, processes, &populated_byte_count, NULL, 0) != 0) {
            int query_error = errno;
            free(processes);
            if (query_error == ENOMEM) {
                continue;
            }
            return query_error;
        }
        size_t process_count = populated_byte_count / sizeof(struct kinfo_proc);
        int inspection_error = inspect_process_snapshot_session(
            processes,
            process_count,
            session_id,
            has_live_member,
            has_live_session_member,
            session_lookup
        );
        free(processes);
        if (inspection_error == EAGAIN) {
            continue;
        }
        return inspection_error;
    }
    return EAGAIN;
}

static int inspect_process_group_session(
    pid_t process_group_id,
    pid_t session_id,
    int *has_live_member,
    int *has_live_session_member
) {
    return inspect_process_group_session_with_lookup(
        process_group_id,
        session_id,
        has_live_member,
        has_live_session_member,
        getsid
    );
}

int holoscape_process_group_has_live_session_member(
    pid_t process_group_id,
    pid_t session_id
) {
    int has_live_member = 0;
    int has_live_session_member = 0;
    int inspection_error = inspect_process_group_session(
        process_group_id,
        session_id,
        &has_live_member,
        &has_live_session_member
    );
    if (inspection_error != 0) {
        return -inspection_error;
    }
    return has_live_session_member;
}

int holoscape_validate_process_group_session(
    pid_t process_group_id,
    pid_t session_id
) {
    int has_live_member = 0;
    int has_live_session_member = 0;
    int inspection_error = inspect_process_group_session(
        process_group_id,
        session_id,
        &has_live_member,
        &has_live_session_member
    );
    if (inspection_error != 0) {
        return -inspection_error;
    }
    if (has_live_session_member) {
        return 1;
    }
    return has_live_member ? -EPROTO : 0;
}

int holoscape_copy_live_session_process_groups(
    pid_t session_id,
    pid_t **process_group_ids,
    size_t *process_group_count
) {
    if (session_id <= 0 || process_group_ids == NULL || process_group_count == NULL) {
        return EINVAL;
    }
    *process_group_ids = NULL;
    *process_group_count = 0;

    int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    for (int attempt = 0; attempt < 3; attempt++) {
        size_t byte_count = 0;
        if (sysctl(query, 3, NULL, &byte_count, NULL, 0) != 0) {
            return errno;
        }
        if (byte_count == 0) {
            continue;
        }
        struct kinfo_proc *processes = malloc(byte_count);
        if (processes == NULL) {
            return ENOMEM;
        }
        size_t populated_byte_count = byte_count;
        if (sysctl(query, 3, processes, &populated_byte_count, NULL, 0) != 0) {
            int query_error = errno;
            free(processes);
            if (query_error == ENOMEM) {
                continue;
            }
            return query_error;
        }

        size_t process_count = populated_byte_count / sizeof(struct kinfo_proc);
        pid_t *groups = malloc(process_count * sizeof(pid_t));
        if (groups == NULL && process_count > 0) {
            free(processes);
            return ENOMEM;
        }
        size_t group_count = 0;
        int saw_session_leader = 0;
        int saw_disappearing_process = 0;
        int snapshot_error = 0;
        for (size_t index = 0; index < process_count; index++) {
            if (processes[index].kp_proc.p_pid == session_id) {
                saw_session_leader = 1;
                break;
            }
        }
        if (!saw_session_leader) {
            free(processes);
            free(groups);
            continue;
        }
        for (size_t index = 0; index < process_count; index++) {
            pid_t member_pid = processes[index].kp_proc.p_pid;
            if (processes[index].kp_proc.p_stat == SZOMB) {
                continue;
            }
            pid_t observed_session = getsid(member_pid);
            if (observed_session < 0) {
                if (errno == ESRCH) {
                    saw_disappearing_process = 1;
                    continue;
                }
                snapshot_error = errno;
                break;
            }
            if (observed_session != session_id) {
                continue;
            }
            pid_t process_group_id = processes[index].kp_eproc.e_pgid;
            if (process_group_id <= 0) {
                snapshot_error = EPROTO;
                break;
            }
            int already_recorded = 0;
            for (size_t group_index = 0; group_index < group_count; group_index++) {
                if (groups[group_index] == process_group_id) {
                    already_recorded = 1;
                    break;
                }
            }
            if (!already_recorded) {
                groups[group_count++] = process_group_id;
            }
        }
        free(processes);

        if (saw_disappearing_process && group_count == 0) {
            free(groups);
            continue;
        }
        if (snapshot_error != 0) {
            free(groups);
            return snapshot_error;
        }
        if (group_count == 0) {
            free(groups);
            return 0;
        }
        *process_group_ids = groups;
        *process_group_count = group_count;
        return 0;
    }
    return EAGAIN;
}

void holoscape_free_process_group_ids(pid_t *process_group_ids) {
    free(process_group_ids);
}

int holoscape_test_sigpipe_safe_handshake_write(void) {
    int descriptors[2];
    if (pipe(descriptors) != 0) {
        return errno;
    }
    int configuration_error = configure_handshake_writer(descriptors[1]);
    close(descriptors[0]);
    if (configuration_error != 0) {
        close(descriptors[1]);
        return configuration_error;
    }
    unsigned char byte = 1;
    int64_t deadline;
    int result = deadline_after_milliseconds(100, &deadline);
    if (result == 0) {
        result = write_exact_until(descriptors[1], &byte, sizeof(byte), deadline);
    }
    close(descriptors[1]);
    return result;
}

int holoscape_test_timed_handshake_read(int timeout_milliseconds) {
    int descriptors[2];
    if (pipe(descriptors) != 0) {
        return errno;
    }
    unsigned char byte = 0;
    int64_t deadline;
    int result = deadline_after_milliseconds(timeout_milliseconds, &deadline);
    if (result == 0) {
        result = read_exact_until(descriptors[0], &byte, sizeof(byte), deadline);
    }
    close(descriptors[0]);
    close(descriptors[1]);
    return result;
}

struct interrupted_sleep_context {
    int remaining_interruptions;
    long interruption_delay_nanoseconds;
};

static int interposed_interrupted_sleep(
    const struct timespec *requested,
    struct timespec *remaining,
    void *raw_context
) {
    struct interrupted_sleep_context *context = raw_context;
    if (context->remaining_interruptions <= 0) {
        return nanosleep(requested, remaining);
    }
    context->remaining_interruptions--;
    struct timespec delay = {
        .tv_sec = 0,
        .tv_nsec = context->interruption_delay_nanoseconds,
    };
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {
    }
    *remaining = *requested;
    errno = EINTR;
    return -1;
}

int holoscape_test_bounded_child_wait_with_eintr(
    int timeout_milliseconds,
    int interruption_count,
    int interruption_delay_microseconds
) {
    pid_t child = fork();
    if (child < 0) {
        return errno;
    }
    if (child == 0) {
        for (;;) {
            pause();
        }
    }

    struct interrupted_sleep_context context = {
        .remaining_interruptions = interruption_count,
        .interruption_delay_nanoseconds = interruption_delay_microseconds * 1000L,
    };
    int result = wait_for_child_bounded_with_sleep(
        child,
        timeout_milliseconds,
        interposed_interrupted_sleep,
        &context
    );
    (void)kill(child, SIGKILL);
    int status;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
    }
    return result;
}

static pid_t disappearing_test_session_lookup(pid_t process_id) {
    (void)process_id;
    errno = ESRCH;
    return -1;
}

int holoscape_test_exhausted_process_group_instability(void) {
    int has_live_member = 0;
    int has_live_session_member = 0;
    return inspect_process_group_session_with_lookup(
        getpgrp(),
        getsid(0),
        &has_live_member,
        &has_live_session_member,
        disappearing_test_session_lookup
    );
}

struct persistent_foreground_instability_context {
    int foreground_attempt_count;
    int child_observation_count;
};

static int persistently_unstable_foreground_snapshot(
    int master_fd,
    pid_t session_id,
    pid_t *foreground_process_group_id,
    void *raw_context
) {
    (void)master_fd;
    (void)session_id;
    (void)foreground_process_group_id;
    struct persistent_foreground_instability_context *context = raw_context;
    context->foreground_attempt_count++;
    return EAGAIN;
}

static int eventually_exited_child_observation(
    pid_t child_pid,
    int *exit_observed,
    void *raw_context
) {
    (void)child_pid;
    struct persistent_foreground_instability_context *context = raw_context;
    context->child_observation_count++;
    *exit_observed = context->child_observation_count >= 5;
    return 0;
}

int holoscape_test_persistent_foreground_instability_observes_exit(void) {
    struct persistent_foreground_instability_context context = {0};
    pid_t foreground_process_group_id = 0;
    int result = observe_pty_exit_with_functions(
        1,
        1,
        -1,
        &foreground_process_group_id,
        persistently_unstable_foreground_snapshot,
        eventually_exited_child_observation,
        &context
    );
    if (result != 0) {
        return result;
    }
    return context.child_observation_count == 5
        && context.foreground_attempt_count == 6
        && foreground_process_group_id == 0
        ? 0
        : EPROTO;
}
