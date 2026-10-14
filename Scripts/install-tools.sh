#!/bin/bash
# Installs the tools Scripts/check.sh uses, with Homebrew, npm and pipx. Used by CI and to set up
# the test VM; running it again only installs what is missing. Needs Xcode (not only the Command
# Line Tools) for xcrun, llvm-cov, leaks, DocC and the sanitizers.
set -euo pipefail
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1

formulae=(swiftlint periphery gitleaks actionlint shellcheck semgrep trivy zizmor markdownlint-cli2
  typos-cli osv-scanner syft hyperfine jq node pipx jemalloc xcodegen)
missing=()
for f in "${formulae[@]}"; do brew list --formula "$f" >/dev/null 2>&1 || missing+=("$f"); done
[[ ${#missing[@]} -gt 0 ]] && brew install --quiet "${missing[@]}"
brew list --cask codeql >/dev/null 2>&1 || brew install --quiet --cask codeql

# Muter comes from its own tap, which Homebrew asks to trust by name.
if ! command -v muter >/dev/null; then
  brew tap --quiet muter-mutation-testing/formulae
  brew trust --formula muter-mutation-testing/formulae/muter 2>/dev/null || true
  brew install --quiet muter
fi

command -v prettier >/dev/null || npm install --global --silent prettier@3
command -v jscpd >/dev/null || npm install --global --silent jscpd@4
# Homebrew's "lizard" is a compressor; the complexity analyser comes from PyPI.
if ! { command -v lizard >/dev/null && lizard --version 2>/dev/null | grep -qE '^1\.'; }; then
  pipx install --force lizard
fi
pipx ensurepath >/dev/null 2>&1 || true
# In GitHub Actions, later steps find pipx's tools only through GITHUB_PATH.
if [[ -n "${GITHUB_PATH:-}" ]]; then echo "$HOME/.local/bin" >> "$GITHUB_PATH"; fi
