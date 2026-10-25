#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
report_path="${1:-$(mktemp "${TMPDIR:-/tmp}/openarc-sync-performance.XXXXXX")}"
report_path="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$report_path")"
export OPENARC_SYNC_PERFORMANCE=1
export TEST_RUNNER_OPENARC_SYNC_PERFORMANCE=1
export OPENARC_SYNC_PERFORMANCE_REPORT="$report_path"
export TEST_RUNNER_OPENARC_SYNC_PERFORMANCE_REPORT="$report_path"
export OPENARC_SYNC_PERFORMANCE_RUN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
export TEST_RUNNER_OPENARC_SYNC_PERFORMANCE_RUN_ID="$OPENARC_SYNC_PERFORMANCE_RUN_ID"
./build.sh test -- -only-testing:OpenArcTests/BrowserSyncPerformanceTests

# A skipped test or wrong filter must not masquerade as a successful probe.
python3 - "$report_path" <<'PY'
import json, os, sys
with open(sys.argv[1]) as source:
    report = json.load(source)
expected = {(phase, tabs, pending) for phase in ('capture', 'empty_pull', 'first_ack')
            for tabs in (100, 1000, 5000) for pending in (0, 10, 100)}
expected |= {('drain', 1000, pending) for pending in (10, 100)}
rows = report['results']
assert report['schemaVersion'] == 1 and report['plannedCases'] == 29
assert report['runID'] == os.environ['OPENARC_SYNC_PERFORMANCE_RUN_ID']
assert len(rows) == 29 and {(r['phase'], r['tabs'], r['pending']) for r in rows} == expected
assert report['allCasesAccountedFor'] and report['completedCases'] > 0
assert report['completedCases'] == sum(r['status'] == 'completed' for r in rows)
for row in rows:
    assert row['status'] in ('completed', 'soft_budget', 'not_applicable')
    if row['status'] == 'completed':
        assert len(row['samplesMilliseconds']) == 3 and 'warmupMilliseconds' in row
    print('SYNC_PERFORMANCE ' + json.dumps(row, sort_keys=True))
print(f"SQLite sync probe: {report['completedCases']}/26 applicable cells completed; "
      f"all 29 cells accounted for; report {sys.argv[1]}")
PY
