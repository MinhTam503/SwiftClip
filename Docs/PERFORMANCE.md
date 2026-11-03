# Performance and measurement

The app uses a single configurable clipboard change-count timer (500 ms by default), a serial storage queue, 60-row history pages and disk-backed payloads/thumbnails. Image previews are downsampled off the main thread. Closing the popup releases its view hierarchy/list. Localized timestamp labels use an opening-time snapshot rather than a real-time UI clock.

## Recorded development measurement

One completed, uninstrumented arm64 Release diagnostic run on macOS 27.2 (2 November 2026) used 1,000 synthetic texts, 100 random 512×512 PNGs and 100 popup open/close cycles:

| State | Physical footprint (MiB) |
| --- | ---: |
| Initial idle | 16.55 |
| After 10 awake minutes idle | 16.30 |
| After 1,000 texts | 16.52 |
| After 100 PNGs | 23.36 |
| Popup with thumbnails | 32.20 |
| After 100 popup cycles | 29.58 |
| After clearing history | 29.86 |

CPU over that idle interval was about 0.037% of one core, computed from process CPU time / monotonic elapsed time. An Apple `leaks` check in a separate profiling run reported 0 leaked bytes for its tested workload. Instruments Allocations completed; a separate Instruments Leaks session stalled while saving, so it was not counted as a completed trace.

These are measurements of the recorded development build/workload, **not promises for later versions, CI runners, larger images or every Mac**. RSS is a different metric: the same run reported about 78.95 MiB RSS after 10 minutes. Framework caches can keep warm footprint above cold-start memory. No RAM/CPU improvement is claimed merely from localization changes.

## Reproduce

```sh
bash Scripts/build_release.sh
bash Scripts/benchmark.sh
```

Keep the diagnostic app open until it exits automatically (about 11 minutes). It uses an isolated temporary database/private pasteboard, a distinct app identity and an hourglass menu icon. A temporary `caffeinate` assertion prevents idle system sleep without permanently changing power settings. The JSON records monotonic/wall time and invalidates a sleep-interrupted run. Short mode does not replace the 10-minute check.

For profiling, use `Scripts/profile.sh Allocations ...` or `Leaks ...`; only its separate profiling copy gets `get-task-allow`. Do not compare instrumented footprint against the uninstrumented baseline. Use Xcode Memory Graph and Activity Monitor for additional manual review; include test duration, data sizes and unresolved observations in any report. Generated measurements/traces stay ignored by Git.
