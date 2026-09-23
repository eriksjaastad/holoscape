# Broker-backed terminal throughput/stall benchmark

Status: implementation note for card #7436.

## Purpose

The #5935 threading audit found that broker-backed terminal input and output needed executable latency coverage while Holoscape incrementally moves broker I/O off the main actor. Broker-backed input now queues through a per-terminal write lane, and output drains through a per-terminal background read lane before feeding SwiftTerm on the main actor. Before changing lower-level broker locking or delivery semantics, Holoscape needs a repeatable baseline that measures the remaining risk: background output load plus foreground typing latency.

## Harness

`BrokerThroughputStallBenchmarkTests` creates:

- one `/bin/cat` session used as the active input probe;
- multiple `/bin/sh` output sessions that print deterministic line bursts;
- repeated input sends into the active probe while output sessions are producing data.

The test records:

- number of output sessions;
- lines per output session;
- bytes drained from output sessions;
- number of input probes;
- max synchronous input-send latency;
- max input echo latency;
- max run-loop probe gap while the harness is draining output;
- total harness duration;
- echoed input tokens observed from the probe session.

The baseline remains XCTest-sized and deterministic enough for normal unit-test runs. It now has three tiers:

1. a small regression case that keeps the original measurement shape cheap;
2. a scaled many-session case that exercises eight output-heavy broker sessions while active input is still being sent and echoed;
3. a bursty case that pushes larger per-line payloads through six sessions and verifies every session drains to its final completion marker.

The scaled and burst tiers are not final daily-driver stress tests. They are the executable seed that future broker-threading cards can expand before changing lower-level runtime locking or transport behavior.

The harness run loop gates exit on per-session completion markers — the final `session-<i>-<last>` line from each output session — rather than a raw byte-count threshold, so the burst tier is not flake-prone under slow spawn or drain skew. The byte floor is derived from the emitted line shape (`outputPayloadBytes` plus the fixed header/footer overhead) instead of a hardcoded per-line constant.

## Run

```sh
swift test --filter BrokerThroughputStallBenchmarkTests
```

Expected small baseline:

- output sessions: 3;
- output lines per session: 80;
- input probes: 8;
- output bytes: at least the payload-aware floor derived from the emitted line shape;
- max synchronous input-send latency budget: `< 0.5s`;
- max input echo latency budget: `< 1.0s`;
- max run-loop probe gap budget: `< 0.35s`;
- total harness duration budget: `< 5s`.

Expected scaled baseline:

- output sessions: 8;
- output lines per session: 220;
- input probes: 24;
- output bytes: at least the payload-aware floor derived from the emitted line shape;
- max synchronous input-send latency budget: `< 0.5s`;
- max input echo latency budget: `< 1.5s`;
- max run-loop probe gap budget: `< 0.5s`;
- total harness duration budget: `< 7s`.

Expected burst baseline:

- output sessions: 6;
- output lines per session: 140;
- input probes: 18;
- payload per output line: 512 bytes;
- output bytes: at least `6 * 140 * (512 + per-line overhead)` — derived from the emitted line shape, not a fixed constant;
- per-session completion: every `session-<i>-0139` marker observed (explicit full drain);
- max synchronous input-send latency budget: `< 0.5s`;
- max input echo latency budget: `< 1.5s`;
- max run-loop probe gap budget: `< 0.5s`;
- total harness duration budget: `< 7s`.

If this starts failing, do not loosen the numbers first. Inspect whether broker I/O, PTY locking, socket transport, or test-host load changed. The benchmark exists to catch main-thread/input-path regressions before lower-level broker scheduling changes are made.
