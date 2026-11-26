# Performance

Targets come from the specification (§11.3) and are planning figures. Numbers below are what was actually measured; anything not measured is marked *open*.

## Environment

macOS 27.0.1, Xcode 27.2, arm64 (development machine). Debug build unless stated.

## Render cost (WP4.6)

`Phase4ViewTests.fiveThousandProcessRenderStaysWithinBudget` renders a synthetic 5,000-process snapshot at 120×40 (overview, table, footer) and diffs it with `ScreenRenderer`, after 5 warm-up frames, over 50 frames.

| Build | Median | Worst | Target |
|---|---|---|---|
| Debug (`swift test`) | ≈1.7 ms | ≈2–4 ms | < ≈16 ms |

The test fails at a median of 50 ms, a deliberately loose bound that still catches an O(n)-per-cell regression without flaking on a busy CI machine. Rendering only draws the visible rows; reduction (sort/filter over 5,000 rows) is covered separately by the sort, filter, and tree tests (5,000-node tree layout ≈20 ms in debug, including a deep chain).

## Idle CPU

`Scripts/pty_idle_check.py` runs the real binary in a pty at the default refresh interval and samples `ps`. Three samples (debug build, 1 s refresh) read 0.3–1.2 % of one core, inside the < ≈3 % target. This is a coarse check, not an Instruments Time Profiler capture.

## Open measurements

- *Open:* Instruments Time Profiler at 1 s refresh on a release build.
- *Open:* Allocations/Leaks over a 30-minute run (no growth trend after warm-up). `leaks` showed 0 leaks in the Phase 0 spike loop only.
- *Open:* slow-collector input-to-update latency (< ≈100 ms). The design (input and rendering on the main actor, collection on its own thread, newest-only delivery) is covered by `SamplingWorkerTests`, but no latency figure has been recorded.

No optimization was made in Phase 4: nothing measured missed its target.
