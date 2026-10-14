#!/bin/bash
# quick.sh   the short stress check: builds the harnesses if needed, then runs the scenarios that
# need little data, one after the other, and says which failed. About 6 minutes after the build
# (the first build takes 5 to 8 minutes), under 1 GB of disk in $TMPDIR/afm-stress, under 1 GB of memory.
#   parallel, stalled provider, flood (2,000 files), viewer on 64 MiB, FileJob (5,000 files, 1 seed),
#   archives (20,000 members, 15 s), Find Files (5 cancels)
# Not in it: the million-file panel, the 4 GiB viewer file, full-size jobs/archives/find (see run.sh).
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/build.sh" || exit 2
failed=()
run() { echo; echo "---- $*"; "$HERE/run.sh" "$@" || failed+=("$*"); }
run parallel
run stalled
run flood 2000 5000 20
run viewer64m
run jobs 5000 1
run archives 20000 15
run find 5
echo
if [ ${#failed[@]} -eq 0 ]; then echo "quick stress check: all 7 scenarios ended without a failure (figures above; logs in $HERE/out/results)"; exit 0; fi
echo "quick stress check: FAILED: ${failed[*]} (logs in $HERE/out/results)"; exit 1
