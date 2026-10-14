#!/bin/bash
# Runs the project's quality gates. Every gate fails the run on the first finding; there are no
# warnings-only modes. Used the same way in the test VM, in the pre-commit hook and in CI.
#
#   Scripts/check.sh            all gates except the slow ones (mutation, sanitizers)
#   Scripts/check.sh <gate>...  only these gates, in this order
#
# Gates:
#   format      swift-format and Prettier leave every file as it is
#   lint        SwiftLint (--strict, every rule but the conflicting ones), swift-format lint
#   docs-lint   markdownlint, typos
#   scripts     ShellCheck, actionlint, zizmor
#   secrets     gitleaks over the whole history
#   security    Semgrep, Trivy, OSV-Scanner
#   codeql      CodeQL security-and-quality queries over the Swift code (slow)
#   deadcode    Periphery: no unused declarations, public ones included
#   complexity  lizard: complexity, length and parameter limits per function
#   duplicates  jscpd: no copied blocks
#   test        the tests, with coverage; Scripts/coverage-gate.py demands 100%
#   docs        DocC builds every module's documentation without a warning
#   sanitizers  the tests again under the address, thread and undefined-behaviour sanitizers (slow)
#   leaks       the tests under `leaks`: no leaked memory
#   mutation    Muter on the files changed since origin/main (slow)
#   sbom        writes build/sbom.spdx.json
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build-tools

fast=(format lint docs-lint scripts secrets security deadcode complexity duplicates test docs leaks)
gates=("$@")
[[ ${#gates[@]} -eq 0 ]] && gates=("${fast[@]}")

# Every Swift file git knows of (tracked, or new and not ignored): sources, tests, the fuzz and stress
# packages and the manifests; never build output or agent worktrees (.claude, ignored).
swift_files() { git ls-files -z --cached --others --exclude-standard -- '*.swift'; }
step() { printf '\n== %s\n' "$*"; }

# SwiftLint 0.65 loads sourcekitdInProc from the nested framework layout (Versions/A); Xcode 27
# ships it flat. A link in the old layout, found through DYLD_FRAMEWORK_PATH, bridges the two.
swiftlint_env() {
  local lib shim
  lib="$(dirname "$(xcrun --find swift)")/../lib/sourcekitdInProc.framework"
  shim="$PWD/.build-tools/sourcekitd"
  if [[ -f "$lib/sourcekitdInProc" && ! -e "$lib/Versions/A/sourcekitdInProc" ]]; then
    mkdir -p "$shim/sourcekitdInProc.framework/Versions/A"
    ln -sfn "$lib/sourcekitdInProc" "$shim/sourcekitdInProc.framework/Versions/A/sourcekitdInProc"
    export DYLD_FRAMEWORK_PATH="$shim${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
  fi
}

for gate in "${gates[@]}"; do
  case "$gate" in
    format)
      step "swift-format"
      swift_files | xargs -0 swift format lint --parallel --strict
      step "Prettier (Markdown)"
      prettier --check --log-level warn "**/*.md"
      ;;
    lint)
      step "SwiftLint"
      swiftlint_env
      swiftlint lint --strict --quiet
      step "SwiftLint analyzer rules"
      swift build --build-tests -v > .build-tools/compile.log 2>&1
      swiftlint analyze --strict --quiet --compiler-log-path .build-tools/compile.log
      ;;
    docs-lint)
      step "markdownlint"
      markdownlint-cli2
      step "typos"
      typos
      ;;
    scripts)
      step "ShellCheck"
      git ls-files -z '*.sh' | xargs -0 shellcheck
      step "actionlint"
      actionlint
      step "zizmor"
      zizmor --quiet .github/workflows
      ;;
    secrets)
      step "gitleaks"
      gitleaks git --no-banner --redact .
      ;;
    security)
      step "Semgrep"
      semgrep scan --error --metrics off --quiet --config p/security-audit --config p/secrets --config p/swift .
      step "Trivy"
      trivy fs --quiet --exit-code 1 --scanners vuln,secret,misconfig .
      step "OSV-Scanner"
      osv-scanner scan source --recursive . || [[ $? -eq 128 ]]  # 128: no package sources to scan
      ;;
    codeql)
      step "CodeQL"
      db=".build-codeql/db"
      rm -rf "$db"
      codeql database create "$db" --language=swift --overwrite --command="swift build --build-tests --scratch-path .build-codeql/build"
      codeql database analyze "$db" codeql/swift-queries:codeql-suites/swift-security-and-quality.qls \
        --format=sarif-latest --output=.build-codeql/results.sarif --download
      python3 -c 'import json,sys; r=[x for run in json.load(open(sys.argv[1]))["runs"] for x in run["results"]]; [print(x["ruleId"], x["locations"][0]["physicalLocation"]["artifactLocation"]["uri"], x["locations"][0]["physicalLocation"]["region"]["startLine"], x["message"]["text"][:120]) for x in r]; sys.exit(1 if r else 0)' .build-codeql/results.sarif
      ;;
    deadcode)
      step "Periphery"
      swift build --build-system native --build-path .build-native \
        -Xswiftc -index-store-path -Xswiftc "$PWD/.build-native/index/store"
      periphery scan --strict --quiet --index-store-path .build-native/index/store
      ;;
    complexity)
      step "lizard"
      lizard --languages swift --CCN 10 --length 60 --arguments 5 --warnings_only Sources
      ;;
    duplicates)
      step "jscpd"
      jscpd --config .jscpd.json Sources
      ;;
    test)
      step "tests with coverage"
      swift test --enable-code-coverage
      python3 Scripts/coverage-gate.py
      ;;
    docs)
      step "DocC"
      swift package generate-documentation --warnings-as-errors
      ;;
    sanitizers)
      for s in address thread undefined; do
        step "tests under the $s sanitizer"
        swift test --sanitize="$s" --scratch-path ".build-$s"
      done
      ;;
    leaks)
      step "tests under leaks"
      Scripts/leak-check.sh
      ;;
    mutation)
      step "Muter on changed files"
      Scripts/mutation.sh
      ;;
    sbom)
      step "SBOM"
      mkdir -p build
      syft scan dir:. --quiet -o spdx-json=build/sbom.spdx.json
      ;;
    *)
      echo "unknown gate: $gate" >&2
      exit 2
      ;;
  esac
done
printf '\nAll gates passed: %s\n' "${gates[*]}"
