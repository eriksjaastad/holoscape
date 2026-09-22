# Broker-backed terminal throughput/stall benchmark

Status: implementation note for card #7436.

## Purpose

The #5935 threading audit found that broker-backed terminal input still crosses the broker synchronously from the main actor, and broker output drains through polling. Before changing broker threading, Holoscape needs a repeatable baseline that measures the specific risk: background output load plus foreground typing latency.

## Harness

`BrokerThroughputStallBenchmarkTests` creates:

- one `/bin/cat` session used as the input probe;
- multiple `/bin/sh` output sessions that print deterministic line bursts;
- repeated input sends into the active probe while output sessions are producing data.

The test records:

- number of output sessions;
- lines per output session;
- bytes drained from output sessions;
- number of input probes;
- max synchronous input-send latency;
- total harness duration;
- echoed input tokens observed from the probe session.

The default XCTest-sized baseline is intentionally small and stable enough to run with normal unit tests. It is not a final daily-driver stress test; it is the executable seed that future broker-threading cards can scale up without inventing a new measurement shape.

## Run

```sh
swift test --filter BrokerThroughputStallBenchmarkTests
```

Expected local baseline from the initial implementation:

- output sessions: 3;
- output lines per session: 80;
- input probes: 8;
- output bytes: at least `3 * 80 * 20`;
- max synchronous input-send latency budget: `< 0.5s`;
- total harness duration budget: `< 5s`.

If this starts failing, do not loosen the numbers first. Inspect whether broker I/O, PTY locking, socket transport, or test-host load changed. The benchmark exists to catch main-thread/input-path regressions before async broker lanes and concurrent request handling are implemented.
