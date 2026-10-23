#!/bin/bash
# Mutation testing with Muter. Every mutant must be killed by a test, or be listed in
# Tests/Mutation/equivalent-mutants.txt with the reason no test can tell it apart (an equivalent
# mutant: the changed code behaves the same). Scripts/mutation-gate.py decides.
#
#   Scripts/mutation.sh                  the Swift files under Sources changed since the branch left
#                                        origin/main (MUTATION_BASE=<commit> names another base)
#   Scripts/mutation.sh <file.swift>...  these files
#   Scripts/mutation.sh --all            every file under Sources (takes days: see Scripts/mutation-shard.sh)
#
# Options (before the files):
#   --report-dir <dir>  where the reports go (default .build/mutation/report): muter.json is Muter's
#                       own report, mutants.json one record per mutant with its source text
#   --no-gate           write the reports but do not judge them (a shard of a split run)
#   --count <file>      only list the mutants, run no test: writes "<mutants> <path>" per file
#
# Muter is built from source with the project's fixes (Scripts/build-muter.sh, installed as
# ~/.afm-tools/bin/muter; MUTER=<path> picks another build). Homebrew's Muter 16 cannot be used:
# it loses mutants inside blocks that hold mutants themselves and crashes on Swift 6 syntax.
#
# Muter works on a copy of the project with every mutant compiled in at once, switched on one at a
# time by an environment variable (and by AFM_MUTANT, which the mutated files read once). Before
# Muter starts, Scripts/mutation-map.py records which tests run which lines (a coverage build of the
# unmutated copy, every test run on its own). Muter's test command is this script with --run-tests
# (see muter.conf.yml): it builds once, then for each mutant runs the tests that reach its line,
# and, if they all pass, the whole of their targets (the test target of the mutated file's module
# first and the others after it when the line is not in the map); a mutant no test reaches survives
# at once. Each run has a time limit (MUTATION_TIMEOUT_FACTOR times the target's baseline time,
# plus a minute; a hung mutant counts as killed). Full test logs of every mutant are kept in
# .mutation/logs inside Muter's copy.
set -euo pipefail

targets=(KernelTests PluginTests ShellTests)

# The test targets that test a source file's module most directly.
nearest_targets() {
  case "$1" in
    Sources/AFMKernel/* | Sources/AFMContracts/*) echo KernelTests ;;
    Sources/Plugins/* | Sources/StandardPlugins/*) echo PluginTests ;;
    Sources/AFMShell/* | Sources/AFileManager/*) echo ShellTests ;;
    *) echo "${targets[@]}" ;;
  esac
}

# Prints the processes under a process, all generations, on one line.
descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    printf '%s ' "$child"
    descendants "$child"
  done
}
# Runs a command in its own process group and stops it after a time limit: first with TERM, then
# with KILL. The processes under the command are noted before it is stopped and stopped with it,
# since a test helper can leave the group or outlive its parent; left running, a mutant that
# allocates in a loop fills memory, swap and disk. Returns the command's status, or 124 when the
# limit was reached.
run_limited() {
  local limit="$1" marker pid watcher status=0 tree=()
  shift
  marker="$(mktemp -t mutation-timeout)"
  rm -f "$marker"
  set -m
  "$@" &
  pid=$!
  (
    sleep "$limit" || exit 0
    descendants "$pid" > "$marker"
    read -r -a tree < "$marker" || true
    kill -TERM -- "-$pid" ${tree[@]+"${tree[@]}"}
    sleep 15
    kill -KILL -- "-$pid" ${tree[@]+"${tree[@]}"}
  ) 2> /dev/null &
  watcher=$!
  set +m
  wait "$pid" || status=$?
  kill -TERM -- "-$watcher" 2> /dev/null || true
  wait "$watcher" 2> /dev/null || true
  if [[ -e "$marker" ]]; then
    # The watcher is stopped as soon as the command ends, maybe before its KILL: whatever of the
    # command is still alive is killed here.
    read -r -a tree < "$marker" || true
    kill -KILL -- "-$pid" ${tree[@]+"${tree[@]}"} 2> /dev/null || true
    rm -f "$marker"
    return 124
  fi
  return "$status"
}

# The test command Muter runs, inside its copy of the project. What it prints is Muter's log of
# the run; Muter reads "with N failure" as a kill, so the wording below is part of the protocol.
run_tests() {
  local root state mutant file target base factor
  root="$(cd "$(dirname "$0")/.." && pwd)"
  state="$root/.mutation"
  # The switched-on mutant is the variable Muter set to YES:
  # "<file name without .swift>_<operator>_<line>_<column>_<offset>".
  mutant="$(env | sed -nE 's/^(.+_[A-Za-z]+_[0-9]+_[0-9]+_[0-9]+)=YES$/\1/p' | head -n 1)"
  cd "$root"
  mkdir -p "$state/logs" "$state/baseline"
  factor="${MUTATION_TIMEOUT_FACTOR:-3}"

  if [[ -e "$state/list-only" ]]; then
    echo "${mutant:-baseline}: listed only"
    exit 0
  fi
  if [[ -z "$mutant" ]]; then
    # Muter's switch compares __muterActiveMutant with the mutant's name (Scripts/muter.patch);
    # each mutated file reads it once from AFM_MUTANT, which the test runs below set.
    while IFS= read -r file; do
      if grep -q '__muterActiveMutant == "' "$file" && ! grep -q 'let __muterActiveMutant' "$file"; then
        printf '\n%s\n%s\n' '// The mutant that is switched on (Scripts/mutation.sh).' \
          "private let __muterActiveMutant = getenv(\"AFM_MUTANT\").map { String(cString: \$0) } ?? \"\"" >> "$file"
      fi
    done < "$state/files"
    echo "baseline: building the tests with every mutant compiled in"
    if ! swift build --build-tests > "$state/logs/build.log" 2>&1; then
      cat "$state/logs/build.log"
      echo "baseline build failed"
      exit 1
    fi
    for target in "${targets[@]}"; do
      base=$SECONDS
      if ! swift test --skip-build --disable-xctest --filter "^$target\\." \
        > "$state/logs/baseline-$target.log" 2>&1; then
        cat "$state/logs/baseline-$target.log"
        echo "baseline: $target failed without any mutant"
        exit 1
      fi
      echo $((SECONDS - base)) > "$state/baseline/$target"
      echo "baseline: $target passed in $((SECONDS - base)) s"
    done
    exit 0
  fi

  local name="${mutant%_*_*_*}" first=() rest=() seen=" " inserted=0 mutated="" line selection
  name="${name%_*}"
  while IFS= read -r file; do
    if [[ "$(basename "$file" .swift)" == "$name" ]] && grep -qF "\"$mutant\"" "$file"; then
      inserted=1
      mutated="$file"
      for target in $(nearest_targets "$file"); do
        [[ "$seen" == *" $target "* ]] || first+=("$target")
        seen+="$target "
      done
    fi
  done < "$state/files"
  for target in "${targets[@]}"; do
    [[ "$seen" == *" $target "* ]] || rest+=("$target")
  done
  if [[ $inserted -eq 0 ]]; then
    echo "$mutant: not inserted: Muter did not write this mutant into the source"
    exit 0
  fi
  export AFM_MUTANT="$mutant"

  # The tests that run the mutant's line (Scripts/mutation-map.py), target by target: a kill by
  # them is a kill. When they all pass, the whole of each of their targets runs before the mutant
  # counts as survived (a test that runs the line may break a later one through shared state).
  line="${mutant%_*_*}"
  line="${line##*_}"
  selection="unknown"
  if [[ -e "$state/map.json" ]]; then
    selection="$(python3 "$root/Scripts/mutation-map.py" select --map "$state/map.json" --file "$mutated" \
      --line "$line")"
  fi
  if [[ -z "$selection" ]]; then
    echo "$mutant: survived: no test runs line $line"
    exit 0
  fi
  if [[ "$selection" != "unknown" ]]; then
    local chosen=() target_filter
    while read -r target target_filter; do
      chosen+=("$target")
      [[ "$target_filter" == "all" ]] && target_filter="^$target\\."
      run_target "$mutant" "$target" "$target (selected)" "$target_filter"
    done <<< "$selection"
    first=("${chosen[@]}")
    rest=()
  fi
  # bash 3.2 under set -u counts an empty "${list[@]}" as unset.
  for target in ${first[@]+"${first[@]}"} ${rest[@]+"${rest[@]}"}; do
    run_target "$mutant" "$target" "$target" "^$target\\."
  done
  echo "$mutant: survived"
  exit 0
}

# Runs the tests of one target that match a filter with the mutant switched on, within the time
# limit; a failure or a timeout is a kill and ends the test command.
run_target() {
  local mutant="$1" target="$2" label="$3" filter="$4" limit base status=0
  limit=$(($(cat "$state/baseline/$target") * factor + 60))
  base=$SECONDS
  run_limited "$limit" swift test --skip-build --disable-xctest --filter "$filter" \
    >> "$state/logs/$mutant-$target.log" 2>&1 || status=$?
  if [[ $status -eq 124 ]]; then
    echo "$mutant: killed by $label: timed out after $limit s, with 1 failure"
    exit 1
  elif [[ $status -ne 0 ]]; then
    echo "$mutant: killed by $label after $((SECONDS - base)) s, with 1 failure"
    exit 1
  fi
  echo "$mutant: $label passed in $((SECONDS - base)) s"
}

if [[ "${1:-}" == "--run-tests" ]]; then
  run_tests
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="${MUTATION_WORK:-$root/.build/mutation}"
report_dir="$work/report"
gate=1
all=0
count=""
muter="${MUTER:-$HOME/.afm-tools/bin/muter}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) all=1 ;;
    --no-gate) gate=0 ;;
    --count)
      count="$2"
      shift
      ;;
    --report-dir)
      report_dir="$2"
      shift
      ;;
    --*)
      echo "unknown option: $1" >&2
      exit 2
      ;;
    *) break ;;
  esac
  shift
done

files=()
if [[ $all -eq 1 ]]; then
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files 'Sources/*.swift')
elif [[ $# -gt 0 ]]; then
  for f in "$@"; do
    if [[ "$f" != Sources/*.swift || ! -f "$f" ]]; then
      echo "not a Swift file under Sources: $f" >&2
      exit 2
    fi
    files+=("$f")
  done
else
  base="$(git merge-base HEAD "${MUTATION_BASE:-origin/main}")"
  while IFS= read -r f; do
    [[ -f "$f" ]] && files+=("$f")
  done < <(git diff --name-only --diff-filter=AMR "$base" -- 'Sources/*.swift')
fi
if [[ ${#files[@]} -eq 0 ]]; then
  echo "no Swift files to mutate"
  exit 0
fi
if [[ ! -x "$muter" ]]; then
  echo "no Muter at $muter: build it with Scripts/build-muter.sh" >&2
  exit 2
fi

# Muter copies the folder it runs in to "<folder>_mutated" next to it. It runs in a clean copy of
# the checkout (tracked and new files), so the copy stays small. The build folder of the last run
# goes back in at the same path, so the next build compiles only what changed.
mkdir -p "$work" "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
if ! mkdir "$work/lock" 2> /dev/null; then
  echo "another mutation run uses $work (remove $work/lock if none does)" >&2
  exit 1
fi
trap 'rm -rf "$work/lock"' EXIT
trap 'exit 130' INT TERM
project="$work/project"
rm -rf "$project"
if [[ -d "${project}_mutated/.build" ]]; then
  rm -rf "$work/build-cache"
  mv "${project}_mutated/.build" "$work/build-cache"
fi
rm -rf "${project}_mutated"
mkdir -p "$project/.mutation"
git ls-files -z --cached --others --exclude-standard | rsync -a --from0 --files-from=- ./ "$project/"
# A mutant may leave a value unused, which is only a warning; in this copy warnings stay warnings.
if ! grep -q 'treatAllWarnings(as: .error)' "$project/Package.swift"; then
  echo "Package.swift no longer sets treatAllWarnings(as: .error): update Scripts/mutation.sh" >&2
  exit 1
fi
sed -i '' '/treatAllWarnings(as: .error)/d' "$project/Package.swift"
if [[ -d "$work/build-cache" ]]; then
  mv "$work/build-cache" "$project/.build"
fi
printf '%s\n' "${files[@]}" > "$project/.mutation/files"
git rev-parse HEAD > "$report_dir/commit"
printf '%s\n' "${files[@]}" > "$report_dir/files"

# Muter takes one file per --files-to-mutate (extra words after it are an error).
file_options=()
for f in "${files[@]}"; do file_options+=(--files-to-mutate "$f"); done

if [[ -n "$count" ]]; then
  # The test command answers at once, without building or testing.
  touch "$project/.mutation/list-only"
  gate=0
else
  # Which tests run which lines, from a coverage build of the unmutated copy (its own build folder
  # under $work, kept between runs): each mutant then runs the tests that reach it first.
  echo "mapping which tests run the lines of ${#files[@]} file(s)"
  map_build="$work/map-build"
  if ! (cd "$project" && swift build --build-tests --enable-code-coverage --scratch-path "$map_build") \
    > "$report_dir/map-build.log" 2>&1; then
    tail -n 40 "$report_dir/map-build.log"
    echo "the coverage build for the test map failed; the full log: $report_dir/map-build.log" >&2
    exit 1
  fi
  products="$(cd "$project" && swift build --show-bin-path --scratch-path "$map_build")"
  python3 Scripts/mutation-map.py build --products "$products" --root "$project" \
    --files "$project/.mutation/files" --output "$project/.mutation/map.json" | tee "$report_dir/map.log"
  echo "mutating ${#files[@]} file(s); Muter's log: $report_dir/muter.log"
fi
start=$SECONDS
status=0
(cd "$project" && "$muter" run --skip-update-check --skip-coverage --format json --output "$report_dir/muter.json" \
  "${file_options[@]}") > "$report_dir/muter.log" 2>&1 || status=$?
if [[ $status -ne 0 ]] \
  && grep -q "wasn't able to discover any code it could mutation test" "$report_dir/muter.log"; then
  echo "no mutants in these files"
  echo '{"fileReports": []}' > "$report_dir/muter.json"
elif [[ $status -ne 0 || ! -s "$report_dir/muter.json" ]]; then
  tail -n 40 "$report_dir/muter.log"
  echo "Muter failed (status $status); the full log: $report_dir/muter.log" >&2
  exit 1
fi
# The logs of an earlier run go first: `cp -R` into an existing folder would nest this run's logs
# in it and leave the old ones where this run's are looked for.
rm -rf "$report_dir/logs" "$report_dir/baseline"
cp -R "${project}_mutated/.mutation/logs" "$report_dir/logs" 2> /dev/null || true
cp -R "${project}_mutated/.mutation/baseline" "$report_dir/baseline" 2> /dev/null || true
echo "Muter finished in $((SECONDS - start)) s"

python3 Scripts/mutation-gate.py collect --muter-report "$report_dir/muter.json" --project "$project" \
  --files "$report_dir/files" --commit "$(cat "$report_dir/commit")" --seconds $((SECONDS - start)) \
  --output "$report_dir/mutants.json" ${count:+--counts "$count"}
if [[ $gate -eq 1 ]]; then
  python3 Scripts/mutation-gate.py check "$report_dir/mutants.json"
fi
