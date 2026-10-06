#include "HoloscapeNativePTY.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

static void report_child_error_and_exit(int error_fd, int error_code) {
    int saved_errno = error_code;
    while (write(error_fd, &saved_errno, sizeof(saved_errno)) < 0 && errno == EINTR) {
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

static int wait_for_child(pid_t pid) {
    int status;
    pid_t result;
    do {
        result = waitpid(pid, &status, 0);
    } while (result < 0 && errno == EINTR);
    return result < 0 ? errno : 0;
}

static int write_exact(int descriptor, const void *buffer, size_t count) {
    const unsigned char *cursor = buffer;
    size_t remaining = count;
    while (remaining > 0) {
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

static int read_exact(int descriptor, void *buffer, size_t count) {
    unsigned char *cursor = buffer;
    size_t remaining = count;
    while (remaining > 0) {
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

static int kill_and_wait(pid_t pid, pid_t process_group_id) {
    if (kill(-process_group_id, SIGKILL) != 0 && errno != ESRCH) {
        return errno;
    }
    return wait_for_child(pid);
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
    int *master_fd
) {
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
        int handshake_error = write_exact(error_pipe[1], &child_ready, sizeof(child_ready));
        if (handshake_error != 0) {
            _exit(127);
        }
        unsigned char launch_permission = 0;
        handshake_error = read_exact(launch_pipe[0], &launch_permission, sizeof(launch_permission));
        close(launch_pipe[0]);
        if (handshake_error != 0) {
            report_child_error_and_exit(error_pipe[1], handshake_error);
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

    int child_ready = -1;
    int handshake_error = read_exact(error_pipe[0], &child_ready, sizeof(child_ready));
    if (handshake_error != 0 || child_ready != 0) {
        close(error_pipe[0]);
        close(launch_pipe[1]);
        int signal_error = kill(pid, SIGKILL) == 0 || errno == ESRCH ? 0 : errno;
        int wait_error = signal_error == 0 ? wait_for_child(pid) : 0;
        close(spawned_master);
        if (signal_error != 0) {
            return signal_error;
        }
        if (wait_error != 0) {
            return wait_error;
        }
        return handshake_error != 0 ? handshake_error : EPROTO;
    }

    pid_t observed_process_group_id = getpgid(pid);
    if (observed_process_group_id != pid) {
        int identity_error = observed_process_group_id < 0 ? errno : EPROTO;
        close(error_pipe[0]);
        close(launch_pipe[1]);
        int signal_error = kill(pid, SIGKILL) == 0 || errno == ESRCH ? 0 : errno;
        int wait_error = signal_error == 0 ? wait_for_child(pid) : 0;
        close(spawned_master);
        return signal_error != 0 ? signal_error : (wait_error != 0 ? wait_error : identity_error);
    }

    if (fcntl(spawned_master, F_SETFD, FD_CLOEXEC) != 0) {
        int descriptor_setup_error = errno;
        close(error_pipe[0]);
        close(launch_pipe[1]);
        int cleanup_error = kill_and_wait(pid, observed_process_group_id);
        close(spawned_master);
        return cleanup_error != 0 ? cleanup_error : descriptor_setup_error;
    }

    *child_pid = pid;
    *process_group_id = observed_process_group_id;
    *master_fd = spawned_master;

    unsigned char launch_permission = 1;
    int release_error = write_exact(launch_pipe[1], &launch_permission, sizeof(launch_permission));
    close(launch_pipe[1]);
    if (release_error != 0) {
        close(error_pipe[0]);
        int cleanup_error = kill_and_wait(pid, observed_process_group_id);
        return cleanup_error != 0 ? cleanup_error : release_error;
    }

    int child_error = 0;
    ssize_t bytes_read;
    do {
        bytes_read = read(error_pipe[0], &child_error, sizeof(child_error));
    } while (bytes_read < 0 && errno == EINTR);
    int read_error = bytes_read < 0 ? errno : 0;
    close(error_pipe[0]);

    if (bytes_read > 0 || read_error != 0) {
        int wait_error = wait_for_child(pid);
        if (wait_error != 0) {
            return wait_error;
        }
        if (bytes_read != sizeof(child_error)) {
            return read_error != 0 ? read_error : EPROTO;
        }
        return child_error;
    }

    return 0;
}

int holoscape_wait_pid(pid_t child_pid, int32_t *termination_status) {
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
