#!/usr/bin/env python3
"""Run a command with a process-group timeout and preserve its exit status."""

from __future__ import annotations

import os
import signal
import subprocess
import sys

TERMINATION_GRACE_SECONDS = 5
TIMEOUT_EXIT_STATUS = 124


def stop_process_group(process: subprocess.Popen[bytes], sig: signal.Signals) -> None:
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def main() -> int:
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} SECONDS COMMAND [ARG ...]", file=sys.stderr)
        return 2

    try:
        timeout_seconds = float(sys.argv[1])
    except ValueError:
        print(f"error: invalid timeout: {sys.argv[1]}", file=sys.stderr)
        return 2
    if timeout_seconds <= 0:
        print("error: timeout must be greater than zero", file=sys.stderr)
        return 2

    command = sys.argv[2:]
    try:
        process = subprocess.Popen(command, start_new_session=True)
    except OSError as error:
        print(f"error: cannot start {command[0]}: {error}", file=sys.stderr)
        return 127

    try:
        return process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        print(
            f"error: command timed out after {timeout_seconds:g} seconds: {command[0]}",
            file=sys.stderr,
        )
        stop_process_group(process, signal.SIGTERM)
        try:
            process.wait(timeout=TERMINATION_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            stop_process_group(process, signal.SIGKILL)
            process.wait()
        return TIMEOUT_EXIT_STATUS
    except KeyboardInterrupt:
        stop_process_group(process, signal.SIGINT)
        return process.wait()


if __name__ == "__main__":
    raise SystemExit(main())
