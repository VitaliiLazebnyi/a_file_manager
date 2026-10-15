#!/bin/bash
# Builds the Muter that Scripts/mutation.sh uses and installs it as ~/.afm-tools/bin/muter.
#
# Muter's last release (16, the Homebrew one) parses with an old Swift parser: it crashes on
# Swift 6 code and loses every mutant inside a block that holds a mutant itself, which then
# "survives" without having been tested. Its development branch parses Swift 6 but writes no
# mutant into the sources at all. So Muter is built from a fixed commit of that branch with
# Scripts/muter.patch, which:
#   - finds a mutant's code block by its place in the file, not by syntax-node identity (lost when
#     the file is parsed again or an enclosing block is rewritten): every mutant is written in,
#     nested ones too (inner blocks are rewritten first);
#   - keeps files of the same name in different folders apart (they were merged into one);
#   - swaps a ternary whose second choice holds operators (`c ? a : b..<d`) as a whole;
#   - switches a mutant on with `getenv("<mutant>") != nil`, not
#     `ProcessInfo.processInfo.environment[...]`, which builds the whole environment dictionary
#     every time mutated code runs and made the tests of hot code take hours instead of seconds
#     (a file that imports neither Foundation nor Darwin gets `import func Darwin.getenv`).
set -euo pipefail
cd "$(dirname "$0")/.."

commit=7f1f2584e0a27fc05c952a5c8cdd52b10cc9513f
source_dir="${MUTER_SOURCE:-$PWD/.build-tools/muter}"
install_dir="$HOME/.afm-tools/bin"

if [[ ! -d "$source_dir/.git" ]]; then
  git clone --quiet https://github.com/muter-mutation-testing/muter.git "$source_dir"
fi
git -C "$source_dir" fetch --quiet origin
git -C "$source_dir" checkout --quiet --force "$commit"
git -C "$source_dir" clean --quiet -fd
git -C "$source_dir" apply "$PWD/Scripts/muter.patch"
swift build --package-path "$source_dir" -c release --product muter
mkdir -p "$install_dir"
install -m 755 "$(swift build --package-path "$source_dir" -c release --show-bin-path)/muter" "$install_dir/muter"
echo "installed $install_dir/muter (Muter at $commit with Scripts/muter.patch)"
