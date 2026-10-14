#!/bin/bash
# Builds "build/A File Manager.app" with the Swift Package Manager (no Xcode needed) and signs
# it with the hardened runtime.
#
#   CODESIGN_IDENTITY   the identity to sign with; default "-" (ad hoc: runs on this Mac).
#                       A "Developer ID Application: ..." identity gives a program that can be
#                       notarised; this script never contacts Apple itself.
#   AFM_BUILD_DIR       the build folder of the Swift Package Manager; default ".build".
#   AFM_APP_DIR         where the application is put; default "build".
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${CODESIGN_IDENTITY:--}"
scratch="${AFM_BUILD_DIR:-.build}"
out="${AFM_APP_DIR:-build}"
entitlements="Resources/AFileManager.entitlements"

plutil -lint Resources/Info.plist "$entitlements" >/dev/null

swift build -c release --scratch-path "$scratch"
bin="$(swift build -c release --scratch-path "$scratch" --show-bin-path)"

app="$out/A File Manager.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/AFileManager" "$app/Contents/MacOS/AFileManager"
cp Resources/Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
# Nobody but the owner writes into the bundle, and nothing rides along on the copies
# (a quarantine mark, a Finder comment).
chmod -R u+rwX,go+rX,go-w "$app"
xattr -cr "$app"

# The hardened runtime: environment variables that make the loader take in other libraries
# (DYLD_INSERT_LIBRARIES, DYLD_LIBRARY_PATH) are ignored, only libraries of the system and of
# this signature are loaded, memory is not writable and executable at once, and no debugger
# attaches. The entitlements file grants the one exception the program needs and says which
# were left out. An ad-hoc signature takes no timestamp; a real identity gets a secure one
# from the signing itself when the program is signed for distribution (--timestamp), which
# is the one step here that would ask a server, so it is asked for only then.
timestamp="--timestamp=none"
if [ "$identity" != "-" ] && [ "${AFM_SECURE_TIMESTAMP:-0}" = "1" ]; then timestamp="--timestamp"; fi
codesign --force --options runtime "$timestamp" --entitlements "$entitlements" --sign "$identity" "$app"

# A signature that is not what was asked for is an error, not a warning.
codesign --verify --strict --deep "$app"
details="$(codesign --display --verbose=2 "$app" 2>&1)"
if ! grep -q 'flags=.*runtime' <<<"$details"; then
    echo "error: $app is not signed with the hardened runtime" >&2
    exit 1
fi
signed="$(codesign --display --entitlements - --xml "$app" 2>/dev/null || true)"
for refused in allow-dyld-environment-variables disable-library-validation get-task-allow allow-unsigned-executable-memory; do
    if grep -q "$refused" <<<"$signed"; then
        echo "error: $app carries the entitlement $refused" >&2
        exit 1
    fi
done
echo "Built $app (signed with ${identity/#-/an ad-hoc signature}, hardened runtime)"
