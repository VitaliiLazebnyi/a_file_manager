#!/bin/bash
# The benchmarks of the hot paths (Tests/Benchmarks), held to the limits in
# Tests/Benchmarks/limits.json. Built for speed (release) with testing enabled, which lets the
# benchmarks reach internal parts of a plugin (the archive file system) and costs next to nothing.
#
#   Scripts/benchmarks.sh                    every benchmark, 5 runs each; fails above a limit
#   Scripts/benchmarks.sh --only a,b         these benchmarks
#   Scripts/benchmarks.sh --runs 9           more runs (steadier medians)
#   Scripts/benchmarks.sh --record           measures and writes new limits for this machine
#   Scripts/benchmarks.sh list               the benchmarks and what each measures
#
# Each run of a benchmark is a process of its own (its peak memory is its own); a benchmark over a
# limit is measured once more and the lower median counts. On a busy machine (load above half the
# cores, e.g. other agents' builds in the same VM) nothing is judged: exit status 3.
#
# Limits are kept per kind of machine (model, cores, memory). After a change that makes something
# faster, or one that is slower for a good reason, record again on a quiet machine (nothing else
# running), look at the diff of limits.json, and commit it with the change that caused it. The
# first run makes a folder of 100,000 files and a ZIP of it in .build-tools/bench (kept).
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=.build-tools/bench-build
swift build --quiet -c release -Xswiftc -enable-testing --product Benchmarks --scratch-path "$scratch"
"$(swift build -c release --scratch-path "$scratch" --show-bin-path)/Benchmarks" "$@"
