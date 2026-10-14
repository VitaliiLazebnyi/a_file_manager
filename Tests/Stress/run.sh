#!/bin/bash
# run.sh <scenario> [arguments]     one stress scenario on a release build, alone (a lock keeps two
# measured runs from overlapping), under a time limit, with its data made first and removed after.
#
#   million [files]                  1  a directory of 1,000,000 files in a panel, the whole script
#   stalled                          2  a provider that stops answering; 100 refreshes of the dead share
#   parallel                         3  Parallel.map torture and the main-thread rule
#   flood [files] [per second] [s]   8  changes in a watched folder (default 20000 5000 20)
#   viewer64m                        7  viewer on a 64 MiB file: memory per call, then the whole script
#   viewer4g                         7  viewer on a 4 GiB file (killed above 32 GB of memory)
#   viewerfull                       7  the four big files and the truncation rounds (11 GiB on disk)
#   jobs [files] [seeds]             4  FileJob cancel/pause/resume (default 20000 files, 3 seeds)
#   archives [entries] [seconds]     5  ZIP with many members, concurrent stage (default 50000, 30)
#   find [cancels] [million]         6  Find Files cancel storm (default 20; "million" adds the 1M directory)
#
# Environment: STRESS_DATA (default $TMPDIR/afm-stress) where data is made; STRESS_KEEP=1 keeps it;
# STRESS_MIN_FREE_GB (default 20) is what must stay free on that volume.
# Output: out/results/<scenario>.log, and a summary on the terminal (bin/summary.py).
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HERE/out/build/release"
RESULTS="$HERE/out/results"
DATA=${STRESS_DATA:-${TMPDIR:-/tmp}/afm-stress}
DATA=${DATA%/}
MINFREE=${STRESS_MIN_FREE_GB:-20}
scenario=${1:-}; shift
status=0
mkdir -p "$RESULTS" "$DATA"

free_gb() { df -g "$DATA" | awk 'NR==2 {print $4}'; }
# need <GB>: the scenario is skipped when it would leave less than the reserve.
need() {
  local free; free=$(free_gb)
  if [ $((free - $1)) -lt "$MINFREE" ]; then
    echo "SKIPPED $scenario: needs $1 GB, $free GB free on the volume of $DATA, $MINFREE GB must stay free"; exit 3
  fi
}
build() { [ -x "$BIN/$1" ] || "$HERE/build.sh" "$1" || exit 2; }
# go <log name> <timeout s> <rss limit MB or -> command...
go() {
  local name=$1 timeout=$2 limit=$3; shift 3
  local log="$RESULTS/$name.log"; rm -f "$log" "$log".hang.*
  local extra=(); [ "$limit" != - ] && extra=(--max-rss-mb "$limit")
  python3 "$HERE/bin/run.py" --timeout "$timeout" "${extra[@]}" --env "STRESS_RESULTS=$RESULTS" --cwd "$RESULTS" --log "$log" -- /usr/bin/time -l "$@"
  local code=$?
  python3 "$HERE/bin/summary.py" "$log"
  [ $code -eq 0 ] || status=1
  return $code
}
clean() { [ -n "${STRESS_KEEP:-}" ] || rm -rf "$@"; }

case $scenario in
  million)
    files=${1:-1000000}; need 6; build StressPanel
    [ -d "$DATA/million" ] || python3 "$HERE/bin/gen_million.py" "$DATA/million" "$files" || exit 2
    go million 2400 - "$BIN/StressPanel" million "$DATA/million" "$DATA/panel"
    clean "$DATA/million" "$DATA/panel" ;;
  stalled)
    need 1; build StressPanel
    go stalled 300 - "$BIN/StressPanel" stalled "$DATA/panel"
    clean "$DATA/panel" ;;
  parallel)
    build StressParallel
    go parallel 900 - "$BIN/StressParallel" ;;
  flood)
    need 1; build StressPanel
    go "flood-${1:-20000}" 400 - "$BIN/StressPanel" flood "$DATA/panel" "${1:-20000}" "${2:-5000}" "${3:-20}"
    clean "$DATA/panel" ;;
  viewer64m)
    need 1; build StressViewer; mkdir -p "$DATA/viewer"
    "$BIN/StressViewer" dense "$DATA/viewer/dense64m.txt" 64 || exit 2
    go viewer64m-leak 900 16000 "$BIN/StressViewer" leak "$DATA/viewer/dense64m.txt" "$RESULTS"
    go viewer64m 900 16000 "$BIN/StressViewer" run "$DATA/viewer/dense64m.txt" "$RESULTS" 1
    clean "$DATA/viewer" ;;
  viewer4g)
    need 5; build StressViewer; mkdir -p "$DATA/viewer"
    "$BIN/StressViewer" dense "$DATA/viewer/dense4g.txt" 4096 || exit 2
    go viewer4g 1500 "${STRESS_VIEWER_RSS_MB:-32000}" "$BIN/StressViewer" run "$DATA/viewer/dense4g.txt" "$RESULTS" 1
    clean "$DATA/viewer" ;;
  viewerfull)
    need 12; build StressViewer
    "$BIN/StressViewer" gen "$DATA/viewer" || exit 2
    for file in dense4g sparse4g line2g newlines1g; do
      go "viewer-$file" 1500 "${STRESS_VIEWER_RSS_MB:-32000}" "$BIN/StressViewer" run "$DATA/viewer/$file.txt" "$RESULTS" 1
    done
    go viewer-truncate 1500 "${STRESS_VIEWER_RSS_MB:-32000}" "$BIN/StressViewer" truncate "$DATA/viewer" "$RESULTS" 12
    clean "$DATA/viewer" ;;
  jobs)
    files=${1:-20000}; seeds=${2:-3}; need 4; build StressJobs
    go "jobs-$files" 2400 - "$BIN/StressJobs" --root "$DATA/jobs" --files "$files" --folders $((files / 50)) --big 6 --seeds "$seeds" --memseeds $((seeds * 2)) --results "$RESULTS"
    clean "$DATA/jobs" ;;
  archives)
    entries=${1:-50000}; seconds=${2:-30}; need 2; build StressArchives
    python3 "$HERE/bin/gen_zips.py" "$DATA/archives" "$entries" 2000 || exit 2
    go "archives-big-$entries" 1200 - "$BIN/StressArchives" --mode big --dir "$DATA/archives" --entries "$entries" --seconds "$seconds" --results "$RESULTS"
    clean "$DATA/archives" ;;
  find)
    cancels=${1:-20}; big=-; build StressFind
    if [ "${2:-}" = million ]; then
      need 8; big="$DATA/million"
      [ -d "$big" ] || python3 "$HERE/bin/gen_million.py" "$big" 1000000 || exit 2
    else need 2; fi
    [ -d "$DATA/findtree" ] || "$BIN/StressFind" gen "$DATA/findtree" || exit 2
    go "find-$cancels" 2400 - "$BIN/StressFind" run "$DATA/findtree" "$big" "$RESULTS" "$cancels" 1
    clean "$DATA/findtree" "$DATA/million" ;;
  *)
    sed -n '2,20p' "$0"; exit 2 ;;
esac
[ -n "${STRESS_KEEP:-}" ] || rmdir "$DATA" 2>/dev/null
exit $status
