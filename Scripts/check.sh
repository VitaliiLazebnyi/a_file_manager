#!/bin/bash
# Runs the project's quality gates. Every gate fails the run on the first finding; there are no
# warnings-only modes. Used the same way in the test VM, in the pre-commit hook and in CI.
#
#   Scripts/check.sh            all gates except the slow ones (mutation, sanitizers)
#   Scripts/check.sh <gate>...  only these gates, in this order
#
# Gates:
#   format      swift-format and Prettier leave every file as it is
#   lint        SwiftLint (--strict, every rule but the conflicting ones) and its analyzer rules over
#               every Swift file (the packages, the fuzz and stress packages, the UI tests, the manifests)
#   docs-lint   markdownlint, typos
#   scripts     ShellCheck, actionlint, zizmor
#   secrets     gitleaks over the whole history
#   security    Semgrep, Trivy, OSV-Scanner
#   codeql      CodeQL security-and-quality queries over the Swift code (slow)
#   deadcode    Periphery: no unused declarations, public ones included
#   complexity  lizard: complexity, length and parameter limits per function
#   duplicates  jscpd: no copied blocks
#   architecture  the module rules of Package.swift's header, on the manifest and every import
#   api         no break of the plugin API (AFMKernel, AFMContracts) against origin/main that
#               Scripts/api-breaks.txt does not acknowledge
#   test        the tests, with coverage; Scripts/coverage-gate.py demands 100% of lines, functions and regions
#   memory      long loops (panels, folders, jobs, viewers, archives, a server) must not make the
#               memory footprint grow (Tests/PluginTests/MemoryGrowth)
#   benchmarks  the hot paths within the time and memory limits recorded for this machine
#               (Scripts/benchmarks.sh; slow, and only on a quiet machine)
#   docs      DocC builds every module's documentation without a warning
#   sanitizers  the tests again under the address, thread and undefined-behaviour sanitizers (slow)
#   leaks       the tests under `leaks`: no leaked memory
#   fuzz-smoke  the fuzz drivers: saved reproducers, then a fixed number of seeded inputs per target
#   stress-smoke  the stress harnesses: each scenario once, small and seeded
#   mutation    Muter on the files changed since origin/main (slow)
#   sbom        writes build/sbom.spdx.json
#   uitest      the UI tests (UITests/run.sh, XCUITest); only in the logged-in session, not over SSH
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build-tools

fast=(format lint docs-lint scripts secrets security deadcode complexity duplicates architecture api test memory docs leaks)
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

# analyzer_log <log>: the compiler invocations `swiftlint analyze` reads. SwiftPM prints an invocation
# only for a module it compiles, so each package is built from nothing in a folder of its own: the
# root package, the fuzz and the stress packages (their drivers; the project's sources they reach
# through links are analysed where they live). The manifests and the standalone demo programs get
# invocations of their own.
#
# Swift Testing's macros (@Suite, @Test, #expect) are then moved out of SourceKit's process: with
# `-plugin-path` they run in its in-process plugin server, and when several analyzer rules expand
# them at once SwiftLint 0.65.1 dies (SIGSEGV/SIGABRT, "Attempted to read an unowned reference but
# object ... was already destroyed"; Xcode 27). Through swift-plugin-server, a process per
# compilation, the same macros expand without a crash. See documentation/quality-gates-handover.md.
analyzer_log() {
  local log=$1 package scratch toolchain sdk platform manifest version program
  : > "$log"
  for package in . Tests/Fuzz/pkg Tests/Stress/harness; do
    scratch="$PWD/.build-tools/analyze/$(basename "$(cd "$package" && pwd)")"
    rm -rf "$scratch"
    (cd "$package" && swift build --build-tests -v --scratch-path "$scratch") >> "$log" 2>&1 \
      || { grep -E 'error:' "$log" | sort -u | head -40 >&2; return 1; }
  done
  # The UI tests are an Xcode project (UITests/project.yml); xcodebuild prints the same invocations.
  rm -rf .build-tools/analyze/uitests
  xcodegen generate --quiet --spec UITests/project.yml
  xcodebuild build-for-testing -project UITests/AFileManagerUITests.xcodeproj -scheme AFileManagerUITests \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build-tools/analyze/uitests >> "$log" 2>&1 \
    || { grep -E 'error:' "$log" | sort -u | head -40 >&2; return 1; }
  toolchain=$(dirname "$(dirname "$(xcrun --find swift)")")
  sdk=$(xcrun --show-sdk-path)
  platform=$(xcrun --show-sdk-platform-path)
  for manifest in Package.swift Tests/Fuzz/pkg/Package.swift Tests/Stress/harness/Package.swift; do
    # PackageDescription's API is available by the manifest's tools version, as SwiftPM compiles it.
    version=$(sed -n '1s/.*swift-tools-version: *\([0-9.]*\).*/\1/p' "$manifest")
    echo "swiftc -module-name main -swift-version 6 -sdk $sdk -target arm64-apple-macosx14.0" \
      "-Xfrontend -package-description-version -Xfrontend $version" \
      "-I $toolchain/lib/swift/pm/ManifestAPI -I $platform/Developer/usr/lib" \
      "-F $platform/Developer/Library/Frameworks $PWD/$manifest" >> "$log"
  done
  for program in Tests/Fuzz/repro/misc/cf/*.swift; do
    echo "swiftc -module-name main -swift-version 6 -sdk $sdk -target arm64-apple-macosx14.0 $PWD/$program" >> "$log"
  done
  sed -i '' "s|-plugin-path $toolchain/lib/swift/host/plugins/testing|-external-plugin-path $toolchain/lib/swift/host/plugins/testing#$toolchain/bin/swift-plugin-server|g" "$log"
}

# analyzer_coverage <log>: fails, naming them, when Swift files git knows of have no invocation in the
# log. `swiftlint analyze` skips such files without a word.
invocation_files() {  # the source files the invocations in log $1 name, response files read
  local argument
  # The lines SwiftLint takes: holding `swiftc ` and ` -module-name `.
  grep -F 'swiftc ' "$1" | grep -F ' -module-name ' | tr ' ' '\n' | while read -r argument; do
    if [[ $argument == @* ]]; then
      cat "${argument#@}"
      echo
    elif [[ $argument == *.swift ]]; then
      echo "$argument"
    fi
  done | sort -u
}
analyzer_coverage() {
  local missing
  missing=$(comm -23 <(swift_files | tr '\0' '\n' | sed "s|^|$PWD/|" | sort -u) <(invocation_files "$1"))
  if [[ -n "$missing" ]]; then
    printf 'no compiler invocation, cannot be analysed:\n%s\n' "$missing" >&2
    return 1
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
      step "required_deinit (Swift classes only)"
      python3 Scripts/required-deinit.py
      step "SwiftLint analyzer rules"
      analyzer_log .build-tools/compile.log
      analyzer_coverage .build-tools/compile.log
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
      trivy fs --quiet --exit-code 1 --scanners vuln,secret,misconfig --skip-dirs .claude .
      step "OSV-Scanner"
      osv-scanner scan source --recursive . || [[ $? -eq 128 ]]  # 128: no package sources to scan
      ;;
    codeql)
      step "CodeQL"
      if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
        echo "CodeQL's Swift extractor is an Intel program and needs Rosetta:" >&2
        echo "  sudo softwareupdate --install-rosetta --agree-to-license" >&2
        exit 1
      fi
      db=".build-codeql/db"
      rm -rf "$db"
      mkdir -p "$(dirname "$db")"
      codeql database create "$db" --language=swift --overwrite --command="swift build --build-tests --build-system native --disable-sandbox --scratch-path .build-codeql/build"
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
    architecture)
      step "architecture"
      python3 Scripts/architecture.py
      ;;
    api)
      step "plugin API against the baseline"
      Scripts/api-check.sh
      ;;
    test)
      step "tests with coverage"
      mkdir -p .build
      # A bundle that ends early (a crash, or a stopped main run loop: exit 0) must fail the gate too.
      # Atomic counters (owner's decision, 2026-10-21): Swift Testing runs a bundle's tests on several
      # threads, and plain counters both lose counts and wrap below zero, so a region that ran can read 0.
      swift test --enable-code-coverage -Xswiftc -Xllvm -Xswiftc -instrprof-atomic-counter-update-all \
        2>&1 | tee .build/test-run.log
      python3 Scripts/test-run-check.py .build/test-run.log
      python3 Scripts/coverage-gate.py
      ;;
    memory)
      step "memory growth"
      AFM_MEMORY_GROWTH=1 swift test --filter MemoryGrowth
      ;;
    benchmarks)
      step "benchmarks"
      Scripts/benchmarks.sh
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
    fuzz-smoke)
      step "fuzz drivers, short and seeded"
      Tests/Fuzz/smoke.sh
      ;;
    stress-smoke)
      step "stress harnesses, short and seeded"
      Tests/Stress/smoke.sh
      ;;
    mutation)
      step "Muter on changed files"
      Scripts/mutation.sh
      ;;
    uitest)
      step "UI tests"
      UITests/run.sh
      ;;
    sbom)
      step "SBOM"
      mkdir -p build
      # What the project itself declares: its manifests, lock file and workflows; never build
      # output, the checkouts SwiftPM makes there, or agent worktrees (each a copy of the project).
      syft scan dir:. --quiet --source-name "A File Manager" --source-version "$(git describe --always --dirty)" \
        --exclude './.build*' --exclude './.claude' --exclude './.swiftpm' --exclude './build' \
        --exclude './Tests/*/out' --exclude './Tests/*/*/.build' -o spdx-json=build/sbom.spdx.json
      # Every resolved Swift package is in it.
      python3 Scripts/sbom-check.py build/sbom.spdx.json Package.resolved
      ;;
    *)
      echo "unknown gate: $gate" >&2
      exit 2
      ;;
  esac
done
printf '\nAll gates passed: %s\n' "${gates[*]}"
