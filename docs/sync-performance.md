# SQLite sync performance

Measured 2026-10-03 on macOS 26.7 arm64 with Xcode 26.6, Debug configuration. Baseline production code: `03cc4d5`; optimized code at `a538c52` reuses one ISO8601 formatter per capture/projection pass and indexes Space selection once. The protocol, queue contents and conflict rules are unchanged.

Run after the root Build:

```sh
./script/test_sync_performance.sh /tmp/openarc-sync-perf.json
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

Raw reports: `/tmp/openarc-sync-perf-before.json`, `/tmp/openarc-sync-perf-after.json`, `/tmp/openarc-sync-perf-after-repeat.json`; matching `.log` files contain wrapper/test output. They are local artifacts, not committed fixtures. Test results: `.build/xcode/Logs/Test/Test-OpenArc-2026.10.03_04-28-29-+0400.xcresult`, `04-34-49` and `04-37-12` with the same filename prefix/suffix. Normal Test skips this probe; timing is never a pass/fail threshold.

## Re-measured 2026-10-25

Same probe on Xcode 27.1 / Swift 6.4, Debug, code at `edaddaf`; all 26 applicable cells completed (raw report `/tmp/openarc-sync-perf-2026-10-25.json`, local only). Medians in milliseconds:

| Operation | Tabs | Pending rows | ms |
| --- | ---: | ---: | ---: |
| capture | 1,000 | 0 | 50.3 |
| capture | 5,000 | 0 | 233.3 |
| empty_pull | 5,000 | 100 | 611.8 |
| first_ack | 5,000 | 100 | 615.5 |
| drain | 1,000 | 10 | 434.4 |
| drain | 1,000 | 100 | 7,571.2 |

The drain stays quadratic: each ACK replays the remaining queue and rewrote every snapshot row (about 75 ms per ACK at 1,000 tabs).

The next commit skips that rewrite when the projection equals the stored snapshot, including the local titles, icons and colors that snapshot equality ignores; an ACK of a change already shown locally is the usual case. Two rollback tests injected their failure into that rewrite, so they now inject it into the baseline write in the same transaction (`syncOutboxAckAndPullRollbackBaselineQueueProjectionAndCursorOnFailure`, `folderBootstrapRollsBackAdoptionVersionCursorAndProjectionOnDatabaseFailure`), and a new test proves an ACK of a shown change writes no tab rows. Medians after the change (same probe, raw report `/tmp/openarc-sync-perf-2026-10-25-skip.json`):

| Operation | Tabs | Pending rows | Before, ms | After, ms |
| --- | ---: | ---: | ---: | ---: |
| empty_pull | 5,000 | 0 | 192.5 | 129.1 |
| first_ack | 5,000 | 10 | 228.8 | 160.6 |
| first_ack | 5,000 | 100 | 615.5 | 562.4 |
| drain | 1,000 | 10 | 434.4 | 305.6 |
| drain | 1,000 | 100 | 7,571.2 | 6,310.4 |

Capture is unchanged (it always writes a new snapshot). The remaining drain cost is replaying the queue tail on every ACK; that needs an incremental projection, not attempted.

## Re-measured 2026-11-07

Same probe, Xcode 27.1, Debug. A sample of the 100-row drain put most of each ACK in replaying the queue tail, and most of that in `BrowserSyncSemanticProjection.list`: its sort read every rank through the optional payloads inside the comparator, copying their strings on each comparison. `list` now reads each rank once, tests the container before building a key, and `publish` leaves entries that already hold their rank. Queue fingerprints match before and after. Medians in milliseconds:

| Operation | Tabs | Pending rows | Before | After |
| --- | ---: | ---: | ---: | ---: |
| empty_pull | 1,000 | 100 | 114.2 | 80.4 |
| empty_pull | 5,000 | 100 | 595.8 | 437.4 |
| first_ack | 1,000 | 100 | 110.8 | 79.6 |
| first_ack | 5,000 | 100 | 579.0 | 431.4 |
| drain | 1,000 | 10 | 318.8 | 288.2 |
| drain | 1,000 | 100 | 6,702.2 | 5,188.5 |

The drain is still quadratic: every ACK replays the rest of the queue. An incremental projection remains the next step. A per-call index of container members, built from `values` at the start of `apply`, was tried and measured slower (drain 6,114 ms, pull with 100 rows at 1,000 tabs 99.8 ms): hashing every key costs more than the plain scan once the scan builds no keys.

An incremental projection cannot reuse the previous ACK's result as it stands: `BrowserSyncOutboxProjection.effectiveChanges` starts from the baseline's tombstones minus every delete still in the queue (`pendingDeletes`), so replaying the whole queue is not replaying its head and then its tail. Reusing work across ACKs first needs that tombstone rule restated per operation, with deletion dominance (S01, S02, S12) proved again.

## Incremental drain, 2026-11-08

Same probe, Xcode 27.2, Debug, code at `4217e1e` before. The store now keeps a replay memo (`BrowserSyncOutboxReplayMemo`): for the queue it last replayed, the state after the first row and the state after all rows. An ACK removes the head row. If the new start state, built from the updated baseline and the remaining rows, equals the remembered state after the head, the replay of the remaining rows would repeat the remembered one, so its end state is reused. The ACK then replays one row, the next head, instead of the whole queue.

The tombstone rule stays as it was. The start state already applies it, including the `pendingDeletes` of exactly the remaining rows, so comparing start states covers it. The comparison is byte-exact: strings by UTF-8 bytes, ranks by bit pattern, queue rows by stored payload bytes. `==` on `String` would accept two Unicode normalizations of one title.

The memo holds only facts about the pure replay. A rolled-back transaction, a pull, a capture, another account, or a server answer that differs from the local replay can make it miss, never wrong; a miss replays the whole queue as before. Legacy v2 rows always miss: they hide entities without a tombstone value. The first ACK after the store opens also replays the whole queue.

Tests in `BrowserSyncIncrementalReplayTests.swift` compare the memo path with full replay after every step of 180 seeded drains of semantic, folder and mixed queues (creates, re-creates, patches, moves, folder moves, cross-Space moves, deletes, Space deletes), with pulls, appended rows and divergent server answers between ACKs. They check the deletion-dominance rows S01, S02 (move-out in its own row and in the same row) and S12 through the memo, and that a store drain, including a rolled-back ACK, writes what fresh stores write. Queue fingerprints match before and after. Medians in milliseconds:

| Operation | Tabs | Pending rows | Before | After |
| --- | ---: | ---: | ---: | ---: |
| empty_pull | 1,000 | 100 | 82.9 | 84.0 |
| empty_pull | 5,000 | 100 | 425.8 | 432.8 |
| first_ack | 1,000 | 100 | 81.0 | 82.5 |
| first_ack | 5,000 | 100 | 426.5 | 437.7 |
| drain | 1,000 | 10 | 294.5 | 282.8 |
| drain | 1,000 | 100 | 5,621.8 | 2,935.6 |

The drain is now linear in queue length: about 29 ms per ACK for both 10 and 100 rows. The rest of each ACK is reading and writing the baseline and snapshot, which still scales with tab count. Pull and first ACK still replay the whole queue. Raw reports: `/tmp/openarc-sync-perf-incremental-before.json`, `/tmp/openarc-sync-perf-incremental.json` (local only).
