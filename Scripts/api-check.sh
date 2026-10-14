#!/bin/bash
# Fails when the public plugin API (the modules AFMKernel and AFMContracts) breaks against a
# baseline: a declaration removed or renamed, a type or signature changed, a protocol given a
# requirement without a default, isolation or `Sendable` added, and whatever else
# swift-api-digester calls a source break. Plugins written against the baseline must still build.
#
#   Scripts/api-check.sh [baseline]   default: the merge base with origin/main; on origin/main
#                                     itself, the commit before (the merged change)
#
# An intended break is acknowledged in Scripts/api-breaks.txt: the digester's line, exactly as
# this script prints it, under a `# reason:` comment that says why the break is worth it. Every
# break that is not acknowledged fails the gate, and so does every acknowledgement that matches
# no break (it is stale: the break is part of the baseline now, and the line is deleted).
#
# The baseline is checked out into .build-tools/api/<commit>/source and built there; its API dump
# is kept, so a second run against the same baseline only builds the current tree.
# (`swift package diagnose-api-breaking-changes` does the same in principle, but it only compares
# modules of library products, which this package has none of, and fails with the default build
# system; so the digester is called directly.)
set -euo pipefail
cd "$(dirname "$0")/.."

modules=(AFMKernel AFMContracts)
acknowledged="Scripts/api-breaks.txt"
work=".build-tools/api"

if [[ $# -gt 0 ]]; then
  baseline="$(git rev-parse --verify "$1^{commit}")"
else
  baseline="$(git merge-base HEAD origin/main)"
  [[ "$baseline" == "$(git rev-parse HEAD)" ]] && baseline="$(git rev-parse HEAD^)"
fi
echo "API baseline: $(git log -1 --format='%h %s' "$baseline")"

sdk="$(xcrun --show-sdk-path)"
target="arm64-apple-macos14.0"
dump() {  # dump <module> <folder with the built modules> <output>
  xcrun swift-api-digester -dump-sdk -module "$1" -I "$2" -sdk "$sdk" -target "$target" \
    -module-cache-path "$work/module-cache" -abort-on-module-fail -avoid-location -avoid-tool-args -o "$3"
}

base="$work/$baseline"
if [[ ! -f "$base/done" ]]; then
  rm -rf "$base"
  mkdir -p "$base/source"
  git archive "$baseline" | tar -x -C "$base/source"
  (cd "$base/source" && swift build --quiet)
  bin="$(cd "$base/source" && swift build --show-bin-path)"
  for module in "${modules[@]}"; do dump "$module" "$bin" "$base/$module.json"; done
  rm -rf "$base/source"
  touch "$base/done"
fi

swift build --quiet
bin="$(swift build --show-bin-path)"
breaks="$work/breaks.txt"
: > "$breaks"
for module in "${modules[@]}"; do
  dump "$module" "$bin" "$work/current-$module.json"
  # The digester writes its findings as `/* section */` headers followed by one line each.
  xcrun swift-api-digester -diagnose-sdk -print-module -input-paths "$base/$module.json" \
    -input-paths "$work/current-$module.json" -o "$work/diagnosis-$module.txt" 2>&1
  grep -v '^/\*' "$work/diagnosis-$module.txt" | grep -v '^[[:space:]]*$' >> "$breaks" || true
done

python3 - "$breaks" "$acknowledged" <<'EOF'
import sys

found = [line.rstrip("\n") for line in open(sys.argv[1]) if line.strip()]
known, problems, reason = {}, [], False
for number, line in enumerate(open(sys.argv[2]), 1):
    text = line.rstrip("\n")
    if not text.strip():
        reason = False
    elif text.startswith("#"):
        reason = reason or text.startswith("# reason:") and len(text) > len("# reason:") + 3
    elif not reason:
        problems.append(f"{sys.argv[2]}:{number}: acknowledged without a `# reason:` line above it: {text}")
    else:
        known[text] = number
for line in found:
    if line not in known:
        problems.append(f"breaking change: {line}")
for line, number in known.items():
    if line not in found:
        problems.append(f"{sys.argv[2]}:{number}: stale, no such break against the baseline (delete it): {line}")
for problem in problems:
    print(problem)
print(f"api: {len(found)} break(s), {len(known)} acknowledged, {len(problems)} problem(s)", file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
