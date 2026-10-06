#include "HoloscapeNativePTY.h"

#include <errno.h>
#include <fcntl.h>
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

int holoscape_spawn_pty(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    uint16_t rows,
    uint16_t columns,
    pid_t *child_pid,
    int *master_fd
) {
    int error_pipe[2];
    if (pipe(error_pipe) != 0) {
        return errno;
    }
    if (fcntl(error_pipe[1], F_SETFD, FD_CLOEXEC) != 0) {
        int error_code = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
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
        return error_code;
    }

    if (pid == 0) {
        close(error_pipe[0]);
        if (working_directory != NULL && chdir(working_directory) != 0) {
            report_child_error_and_exit(error_pipe[1], errno);
        }
        execve(executable, argv, envp);
        report_child_error_and_exit(error_pipe[1], errno);
    }

    *child_pid = pid;
    *master_fd = spawned_master;
    close(error_pipe[1]);
    int child_error = 0;
    ssize_t bytes_read;
    do {
        bytes_read = read(error_pipe[0], &child_error, sizeof(child_error));
    } while (bytes_read < 0 && errno == EINTR);
    int read_error = bytes_read < 0 ? errno : 0;
    close(error_pipe[0]);

    if (bytes_read > 0 || read_error != 0) {
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        }
        return bytes_read > 0 ? child_error : read_error;
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
