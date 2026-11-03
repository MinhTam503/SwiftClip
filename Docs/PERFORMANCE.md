# Performance and measurement

The app uses a single configurable clipboard change-count timer (500 ms by default), a serial storage queue, 60-row history pages and disk-backed payloads/thumbnails. Image previews are downsampled off the main thread. Closing the popup releases its view hierarchy/list. Localized timestamp labels use an opening-time snapshot rather than a real-time UI clock.

## Measurement privacy

Use synthetic data and keep raw measurements, machine specifications, local paths and Instruments traces outside Git. Published source does not need the developer's machine configuration. No memory/CPU target is guaranteed across operating systems or workloads.

## Reproduce

```sh
bash Scripts/build_release.sh
bash Scripts/benchmark.sh
```

Keep the diagnostic app open until it exits automatically (about 11 minutes). It uses an isolated temporary database/private pasteboard, a distinct app identity and an hourglass menu icon. A temporary `caffeinate` assertion prevents idle system sleep without permanently changing power settings. The JSON records monotonic/wall time and invalidates a sleep-interrupted run. Short mode does not replace the 10-minute check.

For profiling, use `Scripts/profile.sh Allocations ...` or `Leaks ...`; only its separate profiling copy gets `get-task-allow`. Do not compare instrumented footprint against the uninstrumented baseline. Use Xcode Memory Graph and Activity Monitor for additional manual review; include test duration, data sizes and unresolved observations in any report. Generated measurements/traces stay ignored by Git.
