#!/bin/bash
# build.sh [product...]   builds the stress harnesses (release, -enable-testing) against the
# project's sources into out/build/release/. Without a product, all six are built.
HERE=$(cd "$(dirname "$0")" && pwd)
[ $# -eq 0 ] && set -- StressPanel StressParallel StressJobs StressArchives StressFind StressViewer
mkdir -p "$HERE/out"
cd "$HERE/harness" || exit 1
status=0
for product in "$@"; do
  swift build --scratch-path "$HERE/out/build" -c release -Xswiftc -enable-testing -Xswiftc -g -j "${STRESS_JOBS:-6}" --product "$product" > "$HERE/out/build-$product.log" 2>&1
  code=$?
  if [ $code -ne 0 ]; then
    status=$code
    echo "BUILD FAILED $product (full log: out/build-$product.log)"
    grep -E "error:" "$HERE/out/build-$product.log" | sort -u | cut -c1-400 | head -80
  else
    echo "built $product"
  fi
done
exit $status
