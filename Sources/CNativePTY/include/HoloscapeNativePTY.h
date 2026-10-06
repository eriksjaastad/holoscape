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
    pid_t *process_group_id,
    int *master_fd,
    int *cleanup_pending
);

int holoscape_observe_pty_exit(
    pid_t child_pid,
    pid_t session_id,
    int master_fd,
    pid_t *foreground_process_group_id
);

int holoscape_reap_pid(pid_t child_pid, int32_t *termination_status);

int holoscape_process_exit_observed(pid_t child_pid);

int holoscape_process_group_has_live_member(
    pid_t process_group_id,
    pid_t excluded_process_id
);

int holoscape_process_group_has_live_session_member(
    pid_t process_group_id,
    pid_t session_id
);

int holoscape_validate_process_group_session(
    pid_t process_group_id,
    pid_t session_id
);

int holoscape_get_foreground_process_group(
    int master_fd,
    pid_t session_id,
    pid_t *foreground_process_group_id
);

int holoscape_test_sigpipe_safe_handshake_write(void);
int holoscape_test_timed_handshake_read(int timeout_milliseconds);
int holoscape_test_bounded_child_wait_with_eintr(
    int timeout_milliseconds,
    int interruption_count,
    int interruption_delay_microseconds
);

#endif
