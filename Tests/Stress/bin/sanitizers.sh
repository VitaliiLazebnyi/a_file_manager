#!/bin/bash
# sanitizers.sh [tsan|asan|normal] [runs]    the project's own test suite under a sanitizer
# (Part A of report 25), built from the project root into Tests/Stress/out/b-<kind>.
#   tsan    ThreadSanitizer (symbolize=0: with symbols it waits for `atos` for ever in some environments)
#   asan    AddressSanitizer + UndefinedBehaviorSanitizer
#   normal  no sanitizer, to see which failures are the load's and not a sanitizer's
# Logs: out/sanitizers/<kind>-<n>.log and the sanitizers' own reports beside them.
# A build takes 10 to 20 minutes and 3 to 5 GB; one run of the suite 2 to 25 minutes.
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
kind=${1:-tsan}; runs=${2:-1}
LOGS="$HERE/out/sanitizers"; mkdir -p "$LOGS"
R=(python3 "$HERE/bin/run.py" --nolock --cwd "$ROOT")
case $kind in
  tsan)   flags=(--sanitize=thread);  env=(--env "TSAN_OPTIONS=halt_on_error=0 symbolize=0 second_deadlock_stack=1 history_size=7 log_path=$LOGS/tsan-report") ;;
  asan)   flags=(--sanitize=address --sanitize=undefined); env=(--env "ASAN_OPTIONS=detect_leaks=0:halt_on_error=0:log_path=$LOGS/asan-report" --env "UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=0") ;;
  normal) flags=(); env=() ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
"${R[@]}" --timeout 3600 --log "$LOGS/build-$kind.log" -- swift build --build-tests "${flags[@]}" --scratch-path "$HERE/out/b-$kind" || exit 2
status=0
for i in $(seq 1 "$runs"); do
  "${R[@]}" --timeout 1800 --log "$LOGS/$kind-$i.log" "${env[@]}" -- swift test --skip-build "${flags[@]}" --scratch-path "$HERE/out/b-$kind" || status=1
done
exit $status
