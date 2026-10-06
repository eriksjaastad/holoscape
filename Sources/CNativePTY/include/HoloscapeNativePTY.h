#ifndef HOLOSCAPE_NATIVE_PTY_H
#define HOLOSCAPE_NATIVE_PTY_H

#include <stdint.h>
#include <sys/types.h>

int holoscape_spawn_pty(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    uint16_t rows,
    uint16_t columns,
    pid_t *child_pid,
    int *master_fd
);

int holoscape_wait_pid(pid_t child_pid, int32_t *termination_status);

#endif
