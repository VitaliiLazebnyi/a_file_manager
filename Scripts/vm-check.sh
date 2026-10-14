#!/bin/bash
# Runs Scripts/check.sh inside the test VM, where the tools are installed, on a copy of this
# working tree (uncommitted changes included). Arguments are passed on: the gates to run.
#
#   AFM_VM_SSH_CONFIG  ssh config with a host "afm-vm"; default ~/Parallels/afm-cache/ssh/config
#   AFM_VM_DIR         where the copy lives in the VM; default afm-check (in the VM user's home)
set -euo pipefail
cd "$(dirname "$0")/.."

config="${AFM_VM_SSH_CONFIG:-$HOME/Parallels/afm-cache/ssh/config}"
dir="${AFM_VM_DIR:-afm-check}"
ssh_cmd=(ssh -F "$config" -o ConnectTimeout=5 afm-vm)

if ! "${ssh_cmd[@]}" true 2>/dev/null; then
  echo "The test VM does not answer over SSH; start it in Parallels (or commit with --no-verify)." >&2
  exit 1
fi
rsync -a --delete \
  --exclude .build --exclude '.build-*' --exclude build --exclude scratchpad \
  --exclude Tests/Fuzz/out --exclude default.profraw \
  -e "ssh -F $config" ./ "afm-vm:$dir/"
quoted=""
for gate in "$@"; do quoted+=" $(printf '%q' "$gate")"; done
"${ssh_cmd[@]}" "source ~/.zshenv; cd $(printf '%q' "$dir") && Scripts/check.sh$quoted"
