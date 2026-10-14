#!/bin/bash
# Mutation testing with Muter. Every mutant must be killed by a test, or be listed in
# Tests/Mutation/equivalent-mutants.txt with the reason no test can tell it apart (an equivalent
# mutant: the changed code behaves the same).
#
#   Scripts/mutation.sh                 the Swift files under Sources changed since origin/main
#   Scripts/mutation.sh <file.swift>... these files
#   Scripts/mutation.sh --all           every file under Sources (takes days; run on spare VMs)
set -euo pipefail
cd "$(dirname "$0")/.."

files=()
if [[ "${1:-}" == "--all" ]]; then
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files 'Sources/*.swift')
elif [[ $# -gt 0 ]]; then
  files=("$@")
else
  base="$(git merge-base HEAD origin/main 2>/dev/null || git rev-list --max-parents=0 HEAD)"
  while IFS= read -r f; do files+=("$f"); done < <(git diff --name-only --diff-filter=AM "$base" -- 'Sources/*.swift')
fi
if [[ ${#files[@]} -eq 0 ]]; then
  echo "no Swift files to mutate"
  exit 0
fi

report="$(mktemp -t muter).json"
muter run --skip-update-check --format json --output "$report" --files-to-mutate "${files[@]}"
python3 Scripts/mutation-gate.py "$report" Tests/Mutation/equivalent-mutants.txt
