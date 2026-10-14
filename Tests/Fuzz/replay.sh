#!/bin/bash
# replay.sh [rel|asan] [filter]
# Builds the drivers (release by default) and runs every saved reproducer listed in
# repro/MANIFEST.tsv and every file under repro/new/ (named <group>-<target>-<anything>).
# Prints one line per reproducer: PASS (the input no longer fails) or FAIL with the signature.
# Exit status 0 when nothing fails. Output: out/replay-<kind>/ (one log per input).
# FZ_REPLAY_SKIP_NEW=1 leaves out repro/new/ (open defects, expected to fail until fixed).
HERE=$(cd "$(dirname "$0")" && pwd)
kind=${1:-rel}; filter=${2:-}
"$HERE/build.sh" "$kind" || exit 2
BIN="$HERE/out/build-$kind/release"
LOGS="$HERE/out/replay-$kind"; rm -rf "$LOGS"; mkdir -p "$LOGS"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/afm-fuzz-replay.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
export ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:symbolize=0
failed=0; total=0
one() {  # file group target env args note
  local file=$1 group=$2 target=$3 env=$4 args=$5 note=$6
  [ -n "$filter" ] && [[ "$file" != *$filter* ]] && return
  total=$((total + 1))
  local log
  log="$LOGS/$(echo "$file" | tr '/ ' '__').log"
  [ "$env" = - ] && env=""; [ "$args" = - ] && args=""
  # shellcheck disable=SC2086
  env FZ_WORK="$WORK" $env "$BIN/fuzz-$group" run "$target" "$HERE/repro/$file" $args > "$log" 2>&1
  local code=$?
  if [ $code -eq 0 ]; then printf 'PASS  %-62s %s %s\n' "$file" "$group/$target" "${env:+($env)}"
  else
    failed=$((failed + 1))
    local why
    why=$(grep -m1 -E '^FZ-(PROPERTY|TIMEOUT|RSS|CRASH)|ERROR: AddressSanitizer|Fatal error' "$log" | cut -c1-160)
    printf 'FAIL  %-62s %s exit=%s %s\n' "$file" "$group/$target" "$code" "$why"
  fi
}
while IFS=$'\t' read -r file group target env args note; do
  case $file in ''|\#*) continue ;; esac
  one "$file" "$group" "$target" "$env" "$args" "$note"
done < "$HERE/repro/MANIFEST.tsv"
if [ -d "$HERE/repro/new" ] && [ -z "${FZ_REPLAY_SKIP_NEW:-}" ]; then
  for path in "$HERE"/repro/new/*.bin; do
    [ -e "$path" ] || continue
    name=$(basename "$path"); group=${name%%-*}; rest=${name#*-}; target=${rest%%--*}
    one "new/$name" "$group" "$target" - - new
  done
fi
echo "replayed $total, failing $failed (logs: $LOGS)"
[ $failed -eq 0 ]
