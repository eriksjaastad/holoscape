# Scrollback and history persistence policy

Status: Phase 3 working policy for #7171/#5884.

## Goal

Relaunch should restore enough per-channel terminal context to understand what a shell or agent was doing, while keeping storage and privacy behavior explicit.

## Current implementation slice

Broker-backed terminal sessions retain a bounded raw-byte scrollback ring in the broker runtime. When Holoscape reattaches a saved broker session after app quit/relaunch, `BrokerBackedTerminalProcess` asks the coordinator for the documented replay tail and feeds it back into the terminal view.

Policy constants live in `ScrollbackPersistencePolicy`:

- `maxRetainedBytesPerSession = 1_048_576` bytes;
- `maxReplayBytesOnReattach = 1_048_576` bytes.

This replaces the earlier audit-only 64 KiB replay cap. The runtime still drops older bytes FIFO once a session exceeds the per-session retention limit.

## Privacy behavior

- Broker session records and channel config persist launch metadata only: command, arguments, working directory, environment profile, lifecycle, and broker session identity.
- Raw terminal output is not written into `sessions.json`, channel config, or broker IPC request logs by this policy.
- Raw terminal output is still retained in the broker runtime scrollback ring until it ages out of the cap.
- Holoscape does not redact output. If a command prints a secret, that secret can be replayed on reattach until it is pushed out of the ring.
- Environment profiles remain named recipes; raw inherited environment values are not serialized into the durable broker registry.

## Remaining #7171 work

- Durable disk-backed scrollback beyond broker-process lifetime is not implemented yet.
- If durable raw scrollback is added later, it needs an opt-in storage location, corruption handling, retention pruning, and secret/privacy tests before use.
- UI should eventually expose enough context about restored scrollback limits that users understand why older output may be missing.
