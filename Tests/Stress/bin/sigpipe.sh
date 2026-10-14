#!/bin/bash
# sigpipe.sh [runs]   PluginTests under ThreadSanitizer with a library injected that writes the
# backtrace of whatever thread raises SIGPIPE (report 25, finding 12). Needs `sanitizers.sh tsan`
# to have built out/b-tsan first. The trap log is out/sanitizers/sigpipe-trap.log (empty = no SIGPIPE).
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LOGS="$HERE/out/sanitizers"; mkdir -p "$LOGS"
cc -dynamiclib -o "$HERE/out/libtrap.dylib" "$HERE/sigpipe/trap.c" || exit 2
for i in $(seq 1 "${1:-6}"); do
  python3 "$HERE/bin/run.py" --nolock --cwd "$ROOT" --timeout 900 --log "$LOGS/tsan-plugin-sigpipe-$i.log" \
    --env "TSAN_OPTIONS=halt_on_error=0 symbolize=0 log_path=$LOGS/tsan-sigpipe-$i" --env "DYLD_INSERT_LIBRARIES=$HERE/out/libtrap.dylib" \
    --env "SIGPIPE_TRAP_LOG=$LOGS/sigpipe-trap.log" -- swift test --skip-build --sanitize=thread --scratch-path "$HERE/out/b-tsan" --filter '^PluginTests\.'
  [ -s "$LOGS/sigpipe-trap.log" ] && break
done
