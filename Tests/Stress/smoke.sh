#!/bin/bash
# smoke.sh   the short, repeatable stress check of Scripts/check.sh (stress-smoke): every harness once,
# on little data, with fixed seeds. Builds the harnesses (release), then runs, each under a time limit:
#   parallel; stalled provider; flood (300 files); million (a panel of 2,000 files); viewer (4 MiB);
#   jobs (300 files, 1 seed); archives (1,000 members, 3 s); Find Files (2,000 files, 2 cancels).
# About 5 minutes after the build, under 1 GB of disk and memory. Not in it: the viewer's leak mode
# (20,000 calls per kind whatever the file; run.sh viewer64m) and the full sizes of run.sh.
# Data: $TMPDIR/afm-stress-smoke (removed at the end). Logs: out/smoke/<scenario>.log.
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/build.sh" || exit 2
BIN="$HERE/out/build/release"
RESULTS="$HERE/out/smoke"; rm -rf "$RESULTS"; mkdir -p "$RESULTS"
DATA=$(mktemp -d "${TMPDIR:-/tmp}/afm-stress-smoke.XXXXXX") || exit 2
trap 'chmod -R u+rwx "$DATA" 2>/dev/null; rm -rf "$DATA"' EXIT
failed=()
# go <name> <timeout s> command...: one scenario, alone and under its time limit, with its summary.
go() {
  local name=$1 timeout=$2; shift 2
  echo; echo "---- $name"
  local code=0
  python3 "$HERE/bin/run.py" --timeout "$timeout" --max-rss-mb 4000 --env "STRESS_RESULTS=$RESULTS" \
    --cwd "$RESULTS" --log "$RESULTS/$name.log" -- "$@" || code=$?
  python3 "$HERE/bin/summary.py" "$RESULTS/$name.log"
  [ $code -eq 0 ] || failed+=("$name")
}
go parallel 600 "$BIN/StressParallel"
go stalled 300 "$BIN/StressPanel" stalled "$DATA/stalled"
go flood 300 "$BIN/StressPanel" flood "$DATA/flood" 300 1000 2
python3 "$HERE/bin/gen_million.py" "$DATA/million" 2000 || exit 2
go million 600 "$BIN/StressPanel" million "$DATA/million" "$DATA/panel" 2000
"$BIN/StressViewer" dense "$DATA/dense4m.txt" 4 || exit 2
go viewer 300 "$BIN/StressViewer" run "$DATA/dense4m.txt" "$RESULTS" 1
go jobs 600 "$BIN/StressJobs" --root "$DATA/jobs" --files 300 --folders 6 --big 1 --seeds 1 --memseeds 1 \
  --results "$RESULTS"
python3 "$HERE/bin/gen_zips.py" "$DATA/archives" 1000 2000 || exit 2
go archives 300 "$BIN/StressArchives" --mode big --dir "$DATA/archives" --entries 1000 --seconds 3 --results "$RESULTS"
"$BIN/StressFind" gen "$DATA/findtree" 40 4 || exit 2
go find 600 "$BIN/StressFind" run "$DATA/findtree" - "$RESULTS" 2 1
echo
if [ ${#failed[@]} -eq 0 ]; then echo "stress smoke: all 8 scenarios passed (logs in $RESULTS)"; exit 0; fi
echo "stress smoke: FAILED: ${failed[*]} (logs in $RESULTS)"; exit 1
