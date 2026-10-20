// AFM UI Mouse: the UI checks XCUITest cannot make, with the system's own mouse events.
//
//   open -W -n --stdout <log> "AFM UI Mouse.app" --args drag <program> <profiles> <left> <right>
//
// XCUITest's drag gestures do not arrive in a virtual machine (its clicks do), and while it
// drives the desktop it holds back events from anyone else; so `run.sh` runs these checks after
// the UI tests, with no XCUITest around. Posting events needs the permission of Privacy &
// Security › Accessibility; the helper is signed with the identity of UITests/identity.sh, so
// the permission, given once, stays. It is started with `open`, so that the permission asked
// for is its own and not the terminal's.
//
// drag: starts the program (its coverage counts go to <profiles>) with <left> in the Thumbnails
// view and <right> in the Full view, drops asked for no confirmation, drags from the middle of
// the left panel (a file: <left> holds enough of them to fill it) to the middle of the right
// one, waits until a file has arrived in <right>, and quits the program. Exit status 0 when the
// file arrived.
import AppKit

Task { @MainActor in
    let arguments = Array(CommandLine.arguments.dropFirst())
    let status: Int32
    switch arguments.first {
    case "drag":
        status = await DesktopCheck.drag(Array(arguments.dropFirst()))

    case "finder-info":
        status = await DesktopCheck.finderInfo(Array(arguments.dropFirst()))

    default:
        print("usage: AFM UI Mouse drag <program> <profiles> <left> <right>")
        print("       AFM UI Mouse finder-info <program> <profiles> <folder>")
        status = 2
    }
    DesktopCheck.releaseModifiers()
    exit(status)
}
NSApplication.shared.run()
