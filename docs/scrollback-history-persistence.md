# Scrollback and history persistence policy

Status: Phase 3 working policy for #7171/#5884.

## Goal

Relaunch should restore enough per-channel terminal context to understand what a shell or agent was doing, while keeping storage and privacy behavior explicit.

## Current implementation slice

Broker-backed terminal sessions retain a bounded raw-byte scrollback ring in the broker runtime and mirror the same bounded tail to disk. When Holoscape reattaches a saved broker session after app quit/relaunch, `BrokerBackedTerminalProcess` asks the coordinator for the documented replay tail and feeds it back into the terminal view with a status line naming whether the replay came from live broker memory or the persisted disk tail. If the in-memory runtime has been replaced, `NativePTYBrokerSessionRuntime` can still read the persisted per-session tail by broker session id.

The runtime retains and replays at most 1 MiB per session, replacing the
earlier audit-only 64 KiB replay cap. It drops older bytes FIFO once a session
exceeds the limit, both in memory and on disk. Disk tails stay within the
selected app-config profile.

## Privacy behavior

- Broker session records and channel config persist launch metadata only: command, arguments, working directory, environment profile, lifecycle, and broker session identity.
- Raw terminal output is not written into `sessions.json`, channel config, or broker IPC request logs by this policy.
- Raw terminal output is written to bounded per-session files under the scrollback directory so it can survive runtime replacement.
- Holoscape does not redact output. If a command prints a secret, that secret can be replayed on reattach until it is pushed out of the per-session cap.
- Environment profiles remain named recipes; raw inherited environment values are not serialized into the durable broker registry.

## Recovery behavior

- If replay succeeds, the terminal shows a one-line restore notice before the replayed bytes and names the replay source plus byte cap.
- If scrollback replay fails after the broker session was successfully reattached, Holoscape keeps the live session attached, writes a warning into the terminal, skips the bad tail, and continues streaming new output. Scrollback corruption must not silently replace or drop the live process.

## Storage maintenance

Appearance Settings includes **Manage Stored Scrollback…**, which opens the
Scrollback Storage window. It lists each non-empty persisted session tail with
its size and last-modified time, and supports confirmed per-session or bulk
clearing without affecting live sessions.

Listing and clearing use the same persistent per-session advisory-lock authority
as broker append, replay, and pruning. The window refreshes after each clear; if
an operation or its cleanup fails, it reports that completion could not be
confirmed instead of claiming success.
