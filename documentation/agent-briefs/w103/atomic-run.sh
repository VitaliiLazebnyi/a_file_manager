#!/bin/bash
# The whole suite with atomic coverage counters, in a build folder of its own; then the gate's report over it.
cd /Users/cm0k/Claude/Projects/TotalCommander || exit 1
S=$(dirname "$0"); SCRATCH=$S/build
FLAGS=(-Xswiftc -Xllvm -Xswiftc -instrprof-atomic-counter-update-all)
swift build --build-tests -j 6 --enable-code-coverage --scratch-path "$SCRATCH" "${FLAGS[@]}" > "$S/build.log" 2>&1 || { echo "build failed"; exit 1; }
B=$(swift build --scratch-path "$SCRATCH" --show-bin-path); rm -rf "$B/codecov"
swift test --skip-build --scratch-path "$SCRATCH" "${FLAGS[@]}" --enable-code-coverage --parallel > "$S/test.log" 2>&1
grep -aE 'Test run with|✘ Test .* failed' "$S/test.log"
xcrun llvm-profdata merge -sparse "$B"/codecov/*.profraw -o "$S/all.profdata"
python3 - "$B" "$S/all.profdata" <<'PY' > "$S/gate.txt"
import json,subprocess,sys,pathlib
b=pathlib.Path(sys.argv[1]); prof=sys.argv[2]
bins=[str(x/"Contents"/"MacOS"/x.stem) for x in sorted(b.glob("*Tests.xctest"))]
objs=[a for x in bins[1:] for a in ("-object",x)]
r=json.loads(subprocess.run(["xcrun","llvm-cov","export","-summary-only","-instr-profile",prof,bins[0],*objs,"-ignore-filename-regex",r"(\.build|/Tests/|/scratchpad/)"],capture_output=True,text=True).stdout)
tot={k:[0,0] for k in ("lines","functions","regions")}
for e in r["data"][0]["files"]:
    n=e["filename"]
    if "/TotalCommander/Sources/" not in n: continue
    s=e["summary"]; miss={k:s[k]["count"]-s[k]["covered"] for k in tot if s[k]["count"]-s[k]["covered"]}
    for k in tot: tot[k][0]+=s[k]["covered"]; tot[k][1]+=s[k]["count"]
    if miss: print(n.split("TotalCommander/")[1], miss)
for k,(c,t) in tot.items(): print(f"{k} {c}/{t} {100*c/t:.2f}%")
PY
tail -3 "$S/gate.txt"
