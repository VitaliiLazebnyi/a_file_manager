#!/bin/bash
# Runs the UI tests: builds the program from the Swift package with coverage counting and a
# bundle identifier of its own (Scripts/build-app.sh), generates the Xcode project of the tests
# (XcodeGen, UITests/project.yml) and runs them with xcodebuild. Must run in the logged-in
# user's session (a terminal there, not SSH): XCUITest drives the program through the window
# server and the accessibility interface.
#
#   UITests/run.sh [xcodebuild options]   e.g. -only-testing:AFileManagerUITests/CopyTests
#
# Everything is written to .build/uitest: the program (app/), the tests' build (derived/), the
# result bundle (results.xcresult) and the program's coverage counts (codecov/ui-*.profraw,
# merged into codecov/ui.profdata).
set -euo pipefail
cd "$(dirname "$0")/.."
out="$PWD/.build/uitest"
command -v xcodegen >/dev/null || { echo "xcodegen is missing: run Scripts/install-tools.sh" >&2; exit 2; }

# The program under test has a bundle identifier of its own, so its preferences, its folder in
# Application Support and its saved windows are not the user's; they start empty and are
# removed again at the end (Xcode runs the tests in an App Sandbox: they cannot do it).
bundle_id=local.a-file-manager.uitests
forget_settings() {
    defaults delete "$bundle_id" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Application Support/$bundle_id" "$HOME/Library/Caches/$bundle_id" \
        "$HOME/Library/Saved Application State/$bundle_id.savedState"
}

# Built like the unit tests are for `swift test --enable-code-coverage` (debug, the same
# compiler flags), so the counts can be merged with theirs. The program is signed with an
# identity that stays from build to build (UITests/identity.sh), so the permission to control
# Finder, given once, stays too (the runner stays ad hoc: see UITests/project.yml).
identity=$(UITests/identity.sh)
AFM_BUILD_DIR="$out/build" AFM_APP_DIR="$out/app" AFM_CONFIGURATION=debug AFM_COVERAGE=1 \
    AFM_BUNDLE_ID="$bundle_id" CODESIGN_IDENTITY="$identity" Scripts/build-app.sh
xcodegen generate --quiet --spec UITests/project.yml

# The helper that makes the checks XCUITest cannot (UITests/MouseHelper: a drag from the
# thumbnails), with the system's own mouse events, after the UI tests. Signed with the same
# identity, so its permission to post events (Accessibility), given once, stays.
mouse="$out/mouse/AFM UI Mouse.app"
rm -rf "$mouse"
mkdir -p "$mouse/Contents/MacOS"
swiftc -O -framework AppKit -o "$mouse/Contents/MacOS/AFM UI Mouse" UITests/MouseHelper/*.swift
cat >"$mouse/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.a-file-manager.uitests.mouse</string>
    <key>CFBundleName</key><string>AFM UI Mouse</string>
    <key>CFBundleExecutable</key><string>AFM UI Mouse</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSBackgroundOnly</key><true/>
</dict>
</plist>
EOF
codesign --force --options runtime --timestamp=none --sign "$identity" "$mouse"

rm -rf "$out/codecov" "$out/results.xcresult"
mkdir -p "$out/codecov"
forget_settings

# A small disk image of its own, attached for the tests of the volume commands (renaming and
# ejecting a drive): the test runner is sandboxed and cannot attach one itself. It is not shown
# in Finder or on the desktop; it is detached and deleted at the end, whether the tests ejected
# it or not.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/afm-uitest.XXXXXX")
device=""
# Called once the tests are done, and on the way out should the script stop before.
finish() {
    # Only while the disk is still this image's: one the tests ejected may have another by now.
    local images
    images=$(hdiutil info)
    if [[ -n "$device" && "$images" == *"$(basename "$scratch")/volume.dmg"* ]]; then
        diskutil eject "$device" >/dev/null || true
    fi
    device=""
    rm -rf "$scratch"
    forget_settings
}
trap finish EXIT
hdiutil create -quiet -size 16m -fs HFS+ -volname "AFM UI Volume" "$scratch/volume.dmg"
attached=$(diskutil image attach --nobrowse "$scratch/volume.dmg")
# The first line names the disk, the last one the volume and where it is mounted.
device=$(head -1 <<<"$attached" | cut -f1 | tr -d '[:space:]')
volume=$(tail -1 <<<"$attached" | cut -f3)
[[ -d "$volume" ]] || { echo "the disk image was not mounted: $attached" >&2; exit 2; }

status=0
# xcodebuild hands TEST_RUNNER_<name> to the tests as <name>.
TEST_RUNNER_AFM_APP="$out/app/A File Manager.app" TEST_RUNNER_AFM_PROFILE_DIR="$out/codecov" \
    TEST_RUNNER_AFM_VOLUME="$volume" \
    xcodebuild test -quiet -project UITests/AFileManagerUITests.xcodeproj -scheme AFileManagerUITests \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$out/derived" \
    -resultBundlePath "$out/results.xcresult" "$@" || status=$?

# The checks XCUITest cannot make (UITests/MouseHelper), with real mouse and key events: the
# drag from the thumbnails, on a left folder with enough files to fill them and an empty right
# one; Finder Info. Only with the whole suite.
if [[ $# -eq 0 ]]; then
    desktop="$scratch/desktop"
    mkdir -p "$desktop/left" "$desktop/right"
    for index in $(seq 1 300); do : >"$desktop/left/file$index.txt"; done
    : >"$out/desktop.log"
    forget_settings
    open -W -n --stdout "$out/desktop.log" --stderr "$out/desktop.log" "$mouse" --args \
        drag "$out/app/A File Manager.app" "$out/codecov" "$desktop/left" "$desktop/right"
    # Finder Info, on a file in a visible folder outside every container (Finder is asked for it).
    finder="$PWD/build/uitest-finder"
    rm -rf "$finder"
    mkdir -p "$finder"
    printf 'Finder shows this file.\n' >"$finder/finder-info.txt"
    forget_settings
    open -W -n --stdout "$out/desktop.log" --stderr "$out/desktop.log" "$mouse" --args \
        finder-info "$out/app/A File Manager.app" "$out/codecov" "$finder"
    rm -rf "$finder"
    cat "$out/desktop.log"
    grep -q "a file arrived" "$out/desktop.log" || status=1
    grep -q "Finder showed the Info window" "$out/desktop.log" || status=1
    if grep -q "stayed open" "$out/desktop.log"; then status=1; fi
fi
finish

# The counts of every run of the program, failed tests included.
profiles=("$out"/codecov/ui-*.profraw)
if [[ -e "${profiles[0]}" ]]; then
    xcrun llvm-profdata merge -sparse "${profiles[@]}" -o "$out/codecov/ui.profdata"
fi
exit "$status"
