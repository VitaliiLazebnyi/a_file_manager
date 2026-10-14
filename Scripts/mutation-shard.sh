#!/bin/bash
# A full mutation run takes days; this splits it over several machines (clones of the test VM).
#
#   Scripts/mutation-shard.sh plan <count>         counts the mutants of every file under Sources and
#                                                  splits the files into <count> shards of about equal
#                                                  test time; prints the plan
#   Scripts/mutation-shard.sh run <shard> <count>  runs one shard (1...count), chunk by chunk
#   Scripts/mutation-shard.sh merge <folder>...    judges the shards' reports together (the gate)
#
# The plan is the same on every machine at the same commit, so each machine works out its own share.
# A shard runs in chunks of about MUTATION_CHUNK_HOURS (default 2) of estimated test time; each
# chunk's report is kept in .build/mutation/shard-<shard>-of-<count>/chunk-<n>, and a chunk already
# done at the same commit is skipped, so `run` continues where an interrupted run stopped.
# The estimate weighs each file's mutants by the time of the test target that runs first for it
# (MUTATION_SECONDS_KernelTests and so on; measured per mutant with every mutant compiled in:
# 35, 165 and 125 seconds).
set -euo pipefail
cd "$(dirname "$0")/.."

work="${MUTATION_WORK:-$PWD/.build/mutation}"
commit="$(git rev-parse HEAD)"

usage() {
  sed -n '4,8p' "$0" >&2
  exit 2
}

# Writes "<mutants> <path>" for every Swift file under Sources, counted by Muter itself (kept per
# commit and Muter build).
count_mutants() {
  local muter counts
  muter="$(shasum "${MUTER:-$HOME/.afm-tools/bin/muter}" | cut -c1-12)"
  counts="$work/counts-$commit-$muter.txt"
  if [[ ! -s "$counts" ]]; then
    Scripts/mutation.sh --count "$counts.tmp" --all > /dev/null
    mv "$counts.tmp" "$counts"
  fi
  echo "$counts"
}

# Prints the plan: "<shard> <chunk> <mutants> <estimated seconds> <path>" per file.
plan() {
  local shards="$1" counts
  counts="$(count_mutants)"
  python3 - "$counts" "$shards" "${MUTATION_CHUNK_HOURS:-2}" << 'EOF'
import os
import sys

counts_path, shards, chunk_hours = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
seconds = {target: float(os.environ.get("MUTATION_SECONDS_" + target, default))
           for target, default in (("KernelTests", 35), ("PluginTests", 165), ("ShellTests", 125))}


def nearest(path):
    if path.startswith(("Sources/AFMKernel/", "Sources/AFMContracts/")):
        return "KernelTests"
    if path.startswith(("Sources/AFMShell/", "Sources/AFileManager/")):
        return "ShellTests"
    return "PluginTests"


files = []
for line in open(counts_path):
    count, path = line.split(maxsplit=1)
    files.append((int(count) * seconds[nearest(path.strip())], int(count), path.strip()))
# Longest first, each to the shard with the least work so far: shards end within one file of each other.
load = [0.0] * shards
members = [[] for _ in range(shards)]
for cost, count, path in sorted(files, key=lambda item: (-item[0], item[2])):
    shard = min(range(shards), key=lambda index: (load[index], index))
    load[shard] += cost
    members[shard].append((path, count, cost))
for shard in range(shards):
    chunk, chunk_cost = 1, 0.0
    for path, count, cost in sorted(members[shard]):
        if chunk_cost > 0 and chunk_cost + cost > chunk_hours * 3600:
            chunk, chunk_cost = chunk + 1, 0.0
        chunk_cost += cost
        print(shard + 1, chunk, count, int(cost), path)
EOF
}

case "${1:-}" in
  plan)
    [[ $# -eq 2 ]] || usage
    plan "$2" | awk '{ n[$1] += $3; s[$1] += $4; c[$1] = $2 > c[$1] ? $2 : c[$1] } END {
      for (k in n) printf "shard %d: %d mutants, %d chunks, about %.1f hours\n", k, n[k], c[k], s[k] / 3600
    }' | sort -n -k2
    ;;
  run)
    [[ $# -eq 3 ]] || usage
    shard="$2"
    out="$work/shard-$shard-of-$3"
    mkdir -p "$out"
    plan "$3" > "$out/plan.txt"
    chunks=()
    while IFS= read -r chunk; do
      chunks+=("$chunk")
    done < <(awk -v s="$shard" '$1 == s { print $2 }' "$out/plan.txt" | sort -un)
    for chunk in "${chunks[@]}"; do
      dir="$out/chunk-$chunk"
      if [[ -s "$dir/mutants.json" && "$(cat "$dir/commit" 2> /dev/null)" == "$commit" ]]; then
        echo "chunk $chunk: done before"
        continue
      fi
      files=()
      while IFS= read -r f; do
        files+=("$f")
      done < <(awk -v s="$shard" -v c="$chunk" '$1 == s && $2 == c { print $5 }' "$out/plan.txt")
      echo "chunk $chunk: ${#files[@]} file(s), started $(date '+%Y-%m-%d %H:%M')"
      rm -rf "$dir"
      Scripts/mutation.sh --no-gate --report-dir "$dir" "${files[@]}"
    done
    echo "shard $shard of $3 done; reports in $out"
    ;;
  merge)
    [[ $# -ge 2 ]] || usage
    shift
    reports=()
    while IFS= read -r f; do reports+=("$f"); done < <(find "$@" -name mutants.json | sort)
    [[ ${#reports[@]} -gt 0 ]] || {
      echo "no mutants.json under $*" >&2
      exit 1
    }
    # Every file under Sources must have been mutated by one of the shards.
    listed='import json, sys; [print(f) for p in sys.argv[1:] for f in json.load(open(p))["files"]]'
    missing="$(comm -23 <(git ls-files 'Sources/*.swift' | sort) <(python3 -c "$listed" "${reports[@]}" | sort -u))"
    if [[ -n "$missing" ]]; then
      echo "files no shard has mutated:" >&2
      echo "$missing" >&2
      exit 1
    fi
    python3 Scripts/mutation-gate.py check "${reports[@]}"
    ;;
  *) usage ;;
esac
