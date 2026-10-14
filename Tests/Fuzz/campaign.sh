#!/bin/bash
# campaign.sh [seconds per group] [groups at a time] [asan|rel] [group...]
# A timed fuzz campaign: every target of every group (or of the groups named), coverage-guided,
# seeded from seeds/ (archives) and from the seeds built into the drivers. The time of a group is
# shared out equally between its targets; the groups run side by side.
# Defaults: 600 s per group, 3 groups at a time, the ASan build. Seven groups then take about 30 minutes (three batches).
# Output: out/runs-<kind>/<group>-<target>/ (corpus, findings/, summary.txt) and a summary at the end.
HERE=$(cd "$(dirname "$0")" && pwd)
seconds=${1:-600}; parallel=${2:-3}; kind=${3:-asan}
shift $(( $# < 3 ? $# : 3 ))
groups=("$@"); [ ${#groups[@]} -eq 0 ] && groups=(arch net tools kernel misc viewer diff)
"$HERE/build.sh" "$kind" "${groups[@]/#/fuzz-}" || exit 2
BIN="$HERE/out/build-$kind/release"
RUNS="$HERE/out/runs-$kind"; mkdir -p "$RUNS"
export FZ_WORK; FZ_WORK=$(mktemp -d "${TMPDIR:-/tmp}/afm-fuzz-campaign.XXXXXX") || exit 2
trap 'chmod -R u+rwx "$FZ_WORK" 2>/dev/null; rm -rf "$FZ_WORK"' EXIT
export ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:symbolize=0
seeds_of() { case $1 in zip*) echo zip;; tar*) echo tar;; tgz*) echo tgz;; txz*) echo txz;; bz) echo bz;; esac; }
one_group() {
  local group=$1
  local targets; targets=$("$BIN/fuzz-$group" list | grep -v -x -e selftest -e quote-demo)
  local count; count=$(echo "$targets" | wc -l)
  local each=$(( seconds / count )); [ $each -lt 5 ] && each=5
  for target in $targets; do
    local extra=(); local s; s=$(seeds_of "$target")
    [ "$group" = arch ] && [ -n "$s" ] && [ -d "$HERE/seeds/$s" ] && extra=(--seeds "$HERE/seeds/$s")
    "$BIN/fuzz-$group" fuzz "$target" --out "$RUNS/$group-$target" --time "$each" "${extra[@]}" > "$RUNS/$group-$target.out" 2>&1
  done
  echo "group $group done"
}
# In batches (the system's bash has no `wait -n`): seven groups, three at a time, are three batches.
running=0
for group in "${groups[@]}"; do
  one_group "$group" &
  running=$((running + 1))
  if [ $running -ge "$parallel" ]; then wait; running=0; fi
done
wait
echo
printf '%-22s %10s %8s %9s  %s\n' target execs edges slowest findings
total=0
for dir in "$RUNS"/*/; do
  name=$(basename "$dir"); f="$dir/summary.txt"; [ -f "$f" ] || continue
  execs=$(awk '$1=="execs"{print $2}' "$f"); edges=$(awk '$1=="edges"{print $2}' "$f"); slow=$(awk '$1=="slowest_ms"{print $2}' "$f")
  found=$(grep -c '^finding ' "$f"); total=$((total + found))
  printf '%-22s %10s %8s %7sms  %s\n' "$name" "$execs" "$edges" "$slow" "$(grep '^finding ' "$f" | cut -c9-120 | tr '\n' ';')"
done
echo "signatures found: $total (inputs under $RUNS/<target>/findings/)"
[ "$total" -eq 0 ]
