#!/usr/bin/env python3
"""Run a command with a process-group timeout and preserve its exit status."""

from __future__ import annotations

import math
import os
import signal
import subprocess
import sys
import time

TERMINATION_GRACE_SECONDS = 5
TIMEOUT_EXIT_STATUS = 124
TERMINATION_FAILURE_EXIT_STATUS = 125
READY_FILE_ENVIRONMENT_VARIABLE = "RUN_WITH_TIMEOUT_READY_FILE"


def stop_process_group(process: subprocess.Popen[bytes], sig: signal.Signals) -> bool:
    try:
        os.killpg(process.pid, sig)
        return True
    except ProcessLookupError:
        return True
    except OSError as error:
        print(
            f"error: cannot signal command group {process.pid} with {sig.name}: {error}",
            file=sys.stderr,
        )
        return False


def process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_for_process_group_exit(
    process: subprocess.Popen[bytes], timeout: float
) -> bool | None:
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        if process.poll() is None:
            try:
                process.wait(timeout=min(0.05, remaining))
            except subprocess.TimeoutExpired:
                continue
        try:
            if not process_group_exists(process.pid):
                return True
        except OSError as error:
            print(
                f"error: cannot inspect command group {process.pid}: {error}",
                file=sys.stderr,
            )
            return None
        time.sleep(min(0.05, remaining))


def stop_and_reap_process_group(
    process: subprocess.Popen[bytes], initial_signal: signal.Signals
) -> bool:
    if not stop_process_group(process, initial_signal):
        return False
    initial_wait = wait_for_process_group_exit(process, TERMINATION_GRACE_SECONDS)
    if initial_wait is not False:
        return initial_wait is True
    if not stop_process_group(process, signal.SIGKILL):
        return False
    final_wait = wait_for_process_group_exit(process, TERMINATION_GRACE_SECONDS)
    if final_wait is not False:
        return final_wait is True
    command_name = (
        process.args[0] if isinstance(process.args, (list, tuple)) else process.args
    )
    print(
        f"error: command group did not exit after SIGKILL: {command_name}",
        file=sys.stderr,
    )
    return False


def publish_ready_file() -> bool:
    ready_file = os.environ.get(READY_FILE_ENVIRONMENT_VARIABLE)
    if ready_file is None:
        return True
    try:
        descriptor = os.open(ready_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(descriptor)
        return True
    except OSError as error:
        print(f"error: cannot publish timeout-runner readiness: {error}", file=sys.stderr)
        return False


def main() -> int:
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} SECONDS COMMAND [ARG ...]", file=sys.stderr)
        return 2

    try:
        timeout_seconds = float(sys.argv[1])
    except ValueError:
        print(f"error: invalid timeout: {sys.argv[1]}", file=sys.stderr)
        return 2
    if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        print("error: timeout must be a finite value greater than zero", file=sys.stderr)
        return 2

    command = sys.argv[2:]
    process: subprocess.Popen[bytes] | None = None
    pending_signal: signal.Signals | None = None

    def forward_termination(signum: int, _frame: object) -> None:
        nonlocal pending_signal
        if process is None:
            pending_signal = signal.Signals(signum)
            return
        for forwarded_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            signal.signal(forwarded_signal, signal.SIG_IGN)
        if stop_and_reap_process_group(process, signal.Signals(signum)):
            raise SystemExit(128 + signum)
        raise SystemExit(TERMINATION_FAILURE_EXIT_STATUS)

    signal.signal(signal.SIGHUP, forward_termination)
    signal.signal(signal.SIGINT, forward_termination)
    signal.signal(signal.SIGTERM, forward_termination)

    if pending_signal is not None:
        return 128 + pending_signal.value
    try:
        process = subprocess.Popen(command, start_new_session=True)
    except OSError as error:
        print(f"error: cannot start {command[0]}: {error}", file=sys.stderr)
        return 127
    if pending_signal is not None:
        if stop_and_reap_process_group(process, pending_signal):
            return 128 + pending_signal.value
        return TERMINATION_FAILURE_EXIT_STATUS
    if not publish_ready_file():
        stop_and_reap_process_group(process, signal.SIGTERM)
        return TERMINATION_FAILURE_EXIT_STATUS

    try:
        status = process.wait(timeout=timeout_seconds)
        if status >= 0:
            try:
                descendants_remain = process_group_exists(process.pid)
            except OSError as error:
                print(
                    f"error: cannot inspect command group {process.pid}: {error}",
                    file=sys.stderr,
                )
                return TERMINATION_FAILURE_EXIT_STATUS
            if descendants_remain and not stop_and_reap_process_group(
                process, signal.SIGTERM
            ):
                return TERMINATION_FAILURE_EXIT_STATUS
            return status
        terminating_signal = signal.Signals(-status)
        if stop_and_reap_process_group(process, terminating_signal):
            return 128 + terminating_signal.value
        return TERMINATION_FAILURE_EXIT_STATUS
    except subprocess.TimeoutExpired:
        print(
            f"error: command timed out after {timeout_seconds:g} seconds: {command[0]}",
            file=sys.stderr,
        )
        if stop_and_reap_process_group(process, signal.SIGTERM):
            return TIMEOUT_EXIT_STATUS
        return TERMINATION_FAILURE_EXIT_STATUS


if __name__ == "__main__":
    raise SystemExit(main())
