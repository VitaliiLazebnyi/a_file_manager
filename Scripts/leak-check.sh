#!/bin/bash
# Runs every test bundle under `leaks --atExit` and fails if a leak's root object is ours.
# Leaks rooted in Apple's libraries are listed in Scripts/known-system-leaks.txt (one type per line).
#
# `leaks` is protected by System Integrity Protection, so DYLD_* variables never reach the test
# process; the testing frameworks are linked into the build folder instead, where the bundles'
# rpath already looks. MallocStackLogging stays off: it is inherited by the tools the tests start
# (unzip, tar, sh) and its messages would end up in their output.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests >/dev/null
bin="$(swift build --show-bin-path)"
helper="$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper"
platform="$(xcrun --show-sdk-platform-path)/Developer"
mkdir -p "$bin/PackageFrameworks"
for item in "$platform/Library/Frameworks/Testing.framework" "$platform/usr/lib/lib_TestingInterop.dylib"; do
  [[ -e "$item" ]] && ln -sfn "$item" "$bin/PackageFrameworks/"
done

known="Scripts/known-system-leaks.txt"
status=0
for bundle in "$bin"/*Tests.xctest; do
  name="$(basename "$bundle" .xctest)"
  binary="$bundle/Contents/MacOS/$name"
  log="$bin/leaks-$name.txt"
  printf '%s: ' "$name"
  set +e
  leaks --atExit -- "$helper" --test-bundle-path "$binary" "$binary" --testing-library swift-testing >"$log" 2>&1
  code=$?
  set -e
  if ! grep -q "Test run with .* passed" "$log"; then
    echo "the tests did not pass under leaks (see $log)"
    status=1
    continue
  fi
  # Root objects of leaks and cycles, minus the known system ones.
  roots="$(grep -E '^ +[0-9]+ \([^)]*\) ROOT (LEAK|CYCLE): <' "$log" \
    | sed -E 's/.*ROOT (LEAK|CYCLE): <([^ >]+).*/\2/' | sort | uniq -c || true)"
  ours="$(printf '%s\n' "$roots" | grep -v -F -f "$known" | sed '/^$/d' || true)"
  if [[ -n "$ours" ]]; then
    echo "leaks (count, root type):"
    printf '%s\n' "$ours"
    status=1
  elif [[ $code -ne 0 && -n "$roots" ]]; then
    echo "only known system leaks"
  else
    echo "no leaks"
  fi
done
exit $status
