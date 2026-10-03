# SQLite sync performance

Measured 2026-10-03 on macOS 26.7 arm64 with Xcode 26.6, Debug configuration. Baseline production code: `51936e4`; optimized code at `727a0f9` reuses one ISO8601 formatter per capture/projection pass and indexes Space selection once. The protocol, queue contents and conflict rules are unchanged.

Run after the root Build:

```sh
./script/test_sync_performance.sh /tmp/thebrowser-sync-perf.json
```

The opt-in Swift Testing probe uses real disposable SQLite stores with 10 Spaces, timestamps, titles and selected tabs. It plans 100/1,000/5,000 tabs × 0/10/100 pending move rows for capture, empty pull and first ACK, plus two queue-drain cases. Three zero-queue ACK cells are inapplicable. Setup and validation count toward a soft 60-second budget but stay outside operation timings. Each cell has one warmup and three fresh-clone samples. A current run ID and all 29 result records are mandatory; incomplete cells have no median.

Validation checks the complete projected snapshot, cursor and remaining row positions/UUIDs/versions/BLOBs. Capture must append only the exact acted-on move. Templates contain the same logical workload across runs; sample databases within a run are cloned from identical bytes. Outbox fingerprints matched across all three runs. Baseline JSON key order and SQLite file layout are not claimed byte-identical between runs.

Median milliseconds (three samples per completed cell):

| Operation | Tabs | Pending rows | Before | After, first | After, repeat |
| --- | ---: | ---: | ---: | ---: | ---: |
| capture | 1,000 | 0 | 117.6 | 58.6 | 54.6 |
| capture | 5,000 | 0 | 579.7 | 306.7 | 222.3 |
| empty_pull | 1,000 | 0 | 95.8 | 92.7 | 71.8 |
| empty_pull | 5,000 | 0 | 461.4 | 404.9 | 297.3 |
| first_ack | 1,000 | 100 | 155.8 | 202.0 | 120.2 |
| first_ack | 5,000 | 100 | 814.8 | 1174.2 | 619.2 |
| drain | 1,000 | 10 | 952.6 | 1149.9 | 572.4 |

The baseline and first optimized run completed 25/26 applicable cells; the unchanged optimized repeat completed 26/26. Draining 100 rows at 1,000 tabs was incomplete in the first two runs, so no comparable median exists. The repeat measured 8,300.2 ms for that drain. Incomplete samples are retained in the raw reports, not treated as completed results.

Capture improved consistently for 1,000/5,000 tabs across both optimized runs. Pull/ACK varied substantially on unchanged code; these runs do not establish a stable speedup for those paths or identify the source of variance. All measurements include synchronous SQLite work on MainActor. Even the improved capture remains above a frame interval for large sessions. This is not live drag/CEF proof or a Release performance guarantee.

Remaining costs include full snapshot writes and baseline coding, sorting/scanning entities per pending semantic operation, and replaying the queue tail after each ACK. No queue/receipt compaction or background persistence was introduced. Preserve FIFO ordering, account isolation, failed-write recovery and immutable payloads in the next architectural step.

Raw reports: `/tmp/thebrowser-sync-perf-before.json`, `/tmp/thebrowser-sync-perf-after.json`, `/tmp/thebrowser-sync-perf-after-repeat.json`; matching `.log` files contain wrapper/test output. They are local artifacts, not committed fixtures. Test results: `.build/xcode/Logs/Test/Test-TheBrowser-2026.10.03_04-28-29-+0400.xcresult`, `04-34-49` and `04-37-12` with the same filename prefix/suffix. Normal Test skips this probe; timing is never a pass/fail threshold.
