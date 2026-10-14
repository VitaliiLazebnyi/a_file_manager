#!/bin/bash
# smoke.sh [execs per target]   the short, repeatable fuzz check of Scripts/check.sh (fuzz-smoke).
# Builds the seven drivers (release), replays the reproducers of repro/MANIFEST.tsv (the open defects
# under repro/new/ are left to replay.sh), then fuzzes every target with a fixed seed for a fixed number
# of inputs (default 200): the same inputs on every run. Exit status 0 when every reproducer passes and
# no target has a finding. Output: out/smoke/ (one folder per target, as a campaign leaves them).
HERE=$(cd "$(dirname "$0")" && pwd)
execs=${1:-200}
FZ_REPLAY_SKIP_NEW=1 "$HERE/replay.sh" rel || exit 1
BIN="$HERE/out/build-rel/release"
OUT="$HERE/out/smoke"; rm -rf "$OUT"; mkdir -p "$OUT"
export FZ_WORK; FZ_WORK=$(mktemp -d "${TMPDIR:-/tmp}/afm-fuzz-smoke.XXXXXX") || exit 2
trap 'chmod -R u+rwx "$FZ_WORK" 2>/dev/null; rm -rf "$FZ_WORK"' EXIT
failed=0; total=0
for group in arch net tools kernel misc viewer diff; do
  # selftest and quote-demo are a positive control and a single-name helper, not fuzz targets.
  for target in $("$BIN/fuzz-$group" list | grep -v -x -e selftest -e quote-demo); do
    total=$((total + 1))
    dir="$OUT/$group-$target"
    # The time is only a backstop: the run ends after $execs inputs.
    "$BIN/fuzz-$group" fuzz "$target" --out "$dir" --time 300 --execs "$execs" --seed 1 > "$dir.out" 2>&1
    code=$?
    found=$(grep -c '^finding ' "$dir/summary.txt" 2>/dev/null)
    ran=$(awk '$1=="execs"{print $2}' "$dir/summary.txt" 2>/dev/null)
    if [ $code -ne 0 ] || [ "${found:-1}" -ne 0 ] || [ "${ran:-0}" -lt "$execs" ]; then
      failed=$((failed + 1))
      printf 'FAIL  %-22s exit=%s execs=%s %s\n' "$group/$target" "$code" "${ran:-?}" \
        "$(grep '^finding ' "$dir/summary.txt" 2>/dev/null | cut -c9-120 | tr '\n' ';')"
    else
      printf 'PASS  %-22s execs=%s\n' "$group/$target" "$ran"
    fi
  done
done
echo "fuzz smoke: $total targets, failing $failed (output: $OUT)"
[ $failed -eq 0 ]
