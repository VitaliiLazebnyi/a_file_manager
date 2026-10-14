#!/bin/bash
# Runs every test bundle, looks for leaked memory with `leaks` when its tests are done, and fails if
# the root object of a leak or a cycle is ours. Leaks rooted in Apple's libraries are listed in
# Scripts/known-system-leaks.txt (patterns, each with the reason).
# Names of bundles (KernelTests ...) as arguments check only those. LEAK_STACKS=1 shows where each
# leaked object was made (see below).
#
# How the process is examined: the test process is started with the system's libLeaksAtExit,
# which stops it when it is about to exit; `leaks` examines it then, and it is let go. This is
# what `leaks --atExit` does, but that also turns MallocStackLogging on, a variable the tools the
# tests start (unzip, tar, ssh) inherit and answer with messages in their output, which fails the
# tests that read it. Any value of the variable does that, so it is not set. LEAK_STACKS=1 uses
# `leaks --atExit` after all, for its stacks (tests that read a tool's output then fail).
#
# The tools the tests start inherit DYLD_INSERT_LIBRARIES too. The system's own ignore it; any
# other stops when it exits just like the test process, and is let go at once.
#
# `leaks` is protected by System Integrity Protection, so DYLD_* variables would never reach the
# test process through it; the testing frameworks are linked into the build folder instead, where
# the bundles' rpath already looks.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests >/dev/null
bin="$(swift build --show-bin-path)"
helper="$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper"
platform="$(xcrun --show-sdk-platform-path)/Developer"
mkdir -p "$bin/PackageFrameworks"
for item in "$platform"/Library/Frameworks/*.framework "$platform"/usr/lib/*.dylib; do
  ln -sfn "$item" "$bin/PackageFrameworks/"
done

# The known patterns, without comments and blank lines (a blank pattern would match every leak).
known="$(sed -E 's/#.*//; s/[[:space:]]+$//; /^$/d' Scripts/known-system-leaks.txt)"

bundles=()
if [[ $# -gt 0 ]]; then
  for name in "$@"; do bundles+=("$bin/$name.xctest"); done
else
  bundles=("$bin"/*Tests.xctest)
fi
for bundle in "${bundles[@]}"; do
  [[ -d "$bundle" ]] || { echo "no test bundle $bundle"; exit 1; }
done

# The processes below `$1` (any depth) that are stopped.
stopped_descendants() {
  ps -A -o pid=,ppid=,stat= | awk -v root="$1" '
    { parent[$1] = $2; state[$1] = $3 }
    END {
      for (pid in parent) {
        for (up = parent[pid]; up != "" && up > 1; up = parent[up]) {
          if (up == root) { if (state[pid] ~ /^T/) print pid; break }
        }
      }
    }'
}

# The root objects in the report of `leaks` in `$1`, one line each: the type, a tab, and what
# `leaks` says about the object (`<Type> [size]  details`, without addresses). A leaked group of
# objects is a tree in the report; only its top counts, the roots inside it are part of it.
# Lines of a tree begin with a count and a size, or (a reference back up) with a field name or
# `CYCLE BACK`; anything else ends the tree. A block `leaks` knows no type of is `untyped`.
leak_roots() {
  awk '
    / << TOTAL >>/ { top = -1; next }
    /^ *[0-9]+ \([^)]*\) / || /-->/ || /^ +CYCLE BACK/ {
      match($0, /^ */)
      indent = RLENGTH
      if (top < 0 || indent <= top) {
        top = indent
        if ($0 ~ / ROOT (LEAK|CYCLE): /) {
          text = $0
          sub(/.* ROOT (LEAK|CYCLE): /, "", text)
          gsub(/ 0x[0-9a-f]+/, "", text)
          type = "untyped"
          if (substr(text, 1, 1) == "<") {
            end = index(text, "> [")
            type = end > 0 ? substr(text, 2, end - 2) : substr(text, 2)
          }
          print type "\t" text
        }
      }
      next
    }
    { top = -1 }
  ' "$1"
}

# Runs the tests of binary `$1` and writes their output, then the report of `leaks`, to `$2`.
# Returns the status of `leaks` (0 no leaks, 1 leaks, more: it failed), or 3 when the tests ended
# before `leaks` could examine them.
run_under_leaks() {
  local binary="$1" log="$2"
  if [[ "${LEAK_STACKS:-}" == 1 ]]; then
    leaks --atExit -- "$helper" --test-bundle-path "$binary" "$binary" --testing-library swift-testing \
      >"$log" 2>&1 && return 0 || return $?
  fi
  DYLD_INSERT_LIBRARIES=/usr/lib/libLeaksAtExit.dylib \
    "$helper" --test-bundle-path "$binary" "$binary" --testing-library swift-testing >"$log" 2>&1 &
  local pid=$! code=3 child
  while kill -0 "$pid" 2>/dev/null; do
    for child in $(stopped_descendants "$pid"); do kill -CONT "$child" 2>/dev/null || true; done
    if [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" == T* ]]; then
      leaks "$pid" >>"$log" 2>&1 && code=0 || code=$?
      kill -CONT "$pid"
      break
    fi
    sleep 1
  done
  wait "$pid" || true
  return $code
}

status=0
for bundle in "${bundles[@]}"; do
  name="$(basename "$bundle" .xctest)"
  binary="$bundle/Contents/MacOS/$name"
  log="$bin/leaks-$name.txt"
  printf '%s: ' "$name"
  code=0
  run_under_leaks "$binary" "$log" || code=$?
  if [[ $code -gt 1 ]] || ! grep -q "^Process [0-9]*: [0-9]* leaks for" "$log"; then
    echo "leaks could not examine the tests (status $code, see $log)"
    status=1
    continue
  fi
  if ! grep -q "Test run with .* passed" "$log" && [[ "${LEAK_STACKS:-}" != 1 ]]; then
    echo "the tests did not pass (see $log)"
    status=1
    continue
  fi
  roots="$(leak_roots "$log")"
  ours="$(printf '%s\n' "$roots" | KNOWN="$known" awk -F '\t' '
    BEGIN { count = split(ENVIRON["KNOWN"], patterns, "\n") }
    NF == 2 {
      for (i = 1; i <= count; i++) if ($2 ~ patterns[i]) next
      print $1
    }' | sort | uniq -c | sort -rn)"
  if [[ -n "$ours" ]]; then
    echo "leaks (count, root type; details in $log):"
    printf '%s\n' "$ours"
    status=1
  elif [[ -n "$roots" ]]; then
    echo "only known system leaks"
  else
    echo "no leaks"
  fi
done
exit $status
