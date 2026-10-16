#!/usr/bin/env python3
"""Run a command with a process-group timeout and preserve its exit status."""

from __future__ import annotations

import math
import os
import signal
import subprocess
import sys

TERMINATION_GRACE_SECONDS = 5
TIMEOUT_EXIT_STATUS = 124
TERMINATION_FAILURE_EXIT_STATUS = 125


def stop_process_group(process: subprocess.Popen[bytes], sig: signal.Signals) -> None:
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def stop_and_reap_process_group(
    process: subprocess.Popen[bytes], initial_signal: signal.Signals
) -> bool:
    stop_process_group(process, initial_signal)
    try:
        process.wait(timeout=TERMINATION_GRACE_SECONDS)
        return True
    except subprocess.TimeoutExpired:
        stop_process_group(process, signal.SIGKILL)
        try:
            process.wait(timeout=TERMINATION_GRACE_SECONDS)
            return True
        except subprocess.TimeoutExpired:
            command_name = (
                process.args[0]
                if isinstance(process.args, (list, tuple))
                else process.args
            )
            print(
                f"error: command did not exit after SIGKILL: {command_name}",
                file=sys.stderr,
            )
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
    try:
        process = subprocess.Popen(command, start_new_session=True)
    except OSError as error:
        print(f"error: cannot start {command[0]}: {error}", file=sys.stderr)
        return 127

    def forward_termination(signum: int, _frame: object) -> None:
        for forwarded_signal in (signal.SIGHUP, signal.SIGTERM):
            signal.signal(forwarded_signal, signal.SIG_IGN)
        stop_and_reap_process_group(process, signal.Signals(signum))
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGHUP, forward_termination)
    signal.signal(signal.SIGTERM, forward_termination)

    try:
        return process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        print(
            f"error: command timed out after {timeout_seconds:g} seconds: {command[0]}",
            file=sys.stderr,
        )
        if stop_and_reap_process_group(process, signal.SIGTERM):
            return TIMEOUT_EXIT_STATUS
        return TERMINATION_FAILURE_EXIT_STATUS
    except KeyboardInterrupt:
        if stop_and_reap_process_group(process, signal.SIGINT):
            return process.returncode
        return TERMINATION_FAILURE_EXIT_STATUS


if __name__ == "__main__":
    raise SystemExit(main())
