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

static int wait_for_child_bounded(pid_t pid, int timeout_milliseconds) {
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
        struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000};
        while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {
        }
    }
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
        return errno;
    }
    if (foreground == 0) {
        *foreground_process_group_id = 0;
        return 0;
    }
    pid_t observed_session = getsid(foreground);
    if (observed_session < 0) {
        return errno;
    }
    if (observed_session != session_id) {
        return EPROTO;
    }
    *foreground_process_group_id = foreground;
    return 0;
}

int holoscape_observe_pty_exit(
    pid_t child_pid,
    pid_t session_id,
    int master_fd,
    pid_t *foreground_process_group_id
) {
    *foreground_process_group_id = 0;
    for (;;) {
        pid_t foreground = 0;
        int foreground_error = holoscape_get_foreground_process_group(
            master_fd,
            session_id,
            &foreground
        );
        if (foreground_error == 0 && foreground > 0) {
            *foreground_process_group_id = foreground;
        } else if (foreground_error == EPROTO) {
            return foreground_error;
        }

        siginfo_t information;
        memset(&information, 0, sizeof(information));
        if (waitid(P_PID, (id_t)child_pid, &information, WEXITED | WNOHANG | WNOWAIT) != 0) {
            if (errno == EINTR) {
                continue;
            }
            return errno;
        }
        if (information.si_pid == child_pid) {
            foreground = 0;
            foreground_error = holoscape_get_foreground_process_group(
                master_fd,
                session_id,
                &foreground
            );
            if (foreground_error == 0 && foreground > 0) {
                *foreground_process_group_id = foreground;
            } else if (foreground_error == EPROTO) {
                return foreground_error;
            }
            return 0;
        }
        struct timespec pause = {.tv_sec = 0, .tv_nsec = 10000000};
        while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {
        }
    }
}

int holoscape_reap_pid(pid_t child_pid, int32_t *termination_status) {
    int status;
    pid_t result;
    do {
        result = waitpid(child_pid, &status, 0);
    } while (result < 0 && errno == EINTR);
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
