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

/// What the program is told on the command line: its folders and settings (the argument domain
/// beats its preferences, as in `AppSession`).
private enum ProgramArguments {
    /// A setting as the program keeps it (JSON), in the property-list form the argument domain
    /// reads: `<hex bytes>` is data.
    static func setting(_ value: Any) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return "<" + json.map { String(format: "%02x", $0) }.joined() + ">"
    }

    /// One tab in `folder`, as the program keeps a panel's tabs (`PanelTabs.State`).
    static func tabs(at folder: URL) -> [String: Any] {
        let tab: [String: Any] = [
            "location": folder.absoluteString, "sortKey": 0, "descending": false, "showHidden": false
        ]
        return ["tabs": [tab], "active": 0]
    }

    /// The arguments of the drag check.
    static func drag(left: URL, right: URL) throws -> [String] {
        let full = ["mode": 0, "extraColumns": [], "columnWidths": [:]] as [String: Any]
        let thumbnails = ["mode": 2, "extraColumns": [], "columnWidths": [:]] as [String: Any]
        var arguments = ["-ApplePersistenceIgnoreState", "YES"]
        for (key, value) in [
            ("left.tabs", tabs(at: left) as Any), ("right.tabs", tabs(at: right)), ("window.sourcePanel", "left"),
            ("window.divider", 500), ("window.panelsStacked", false), ("window.fullScreen", false),
            ("left.view", thumbnails), ("right.view", full), ("panel.confirmDragAndDrop", false)
        ] {
            arguments += ["-" + key, try setting(value)]
        }
        return arguments
    }
}

/// The checks, run on the main thread while the run loop turns.
private enum DesktopCheck {
    /// The title of the program's main window.
    private static let windowTitle = "A File Manager 0.1"
    /// How long anything may take, at most (as `AppSession.patience`).
    private static let patience: TimeInterval = 30
    /// The steps of a drag, and the time between two of them: a hand moves the mouse in steps,
    /// and the system starts a drag only once the pressed mouse has moved for a moment.
    private static let steps = 30
    private static let stepTime: TimeInterval = 0.02

    /// The drag check; its exit status.
    static func drag(_ arguments: [String]) async -> Int32 {
        guard arguments.count == 4 else {
            print("usage: drag <program> <profiles> <left> <right>")
            return 2
        }
        let (program, profiles) = (URL(fileURLWithPath: arguments[0]), arguments[1])
        let left = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let right = URL(fileURLWithPath: arguments[3], isDirectory: true)
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            print("not allowed to post events: Privacy & Security › Accessibility")
            return 1
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ["LLVM_PROFILE_FILE": profiles + "/ui-%p.profraw"]
        do {
            configuration.arguments = try ProgramArguments.drag(left: left, right: right)
            let app = try await NSWorkspace.shared.openApplication(at: program, configuration: configuration)
            defer { quit(app) }
            guard let frame = await until({ mainWindowFrame(of: app.processIdentifier) }) else {
                print("the program showed no main window")
                return 1
            }
            app.activate()
            guard await until({ app.isActive ? true : nil }) != nil else {
                print("the program did not come to the front")
                return 1
            }
            // The middle of each panel: a file of the left one's thumbnails, the right one's list.
            let start = CGPoint(x: frame.minX + frame.width * 0.25, y: frame.midY)
            let end = CGPoint(x: frame.minX + frame.width * 0.75, y: frame.midY)
            await drag(from: start, to: end)
            let arrived = await until { () -> Bool? in
                let names = (try? FileManager.default.contentsOfDirectory(atPath: right.path)) ?? []
                return names.isEmpty ? nil : true
            }
            print(arrived == nil ? "nothing arrived in \(right.path)" : "a file arrived in \(right.path)")
            return arrived == nil ? 1 : 0
        } catch {
            print("the program did not start: \(error)")
            return 1
        }
    }

    /// The frame of the program's main window, in screen points from the top left; nil while
    /// it is not on screen.
    private static func mainWindowFrame(of pid: pid_t) -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where window[kCGWindowOwnerPID as String] as? pid_t == pid {
            // The title needs the permission to record the screen; the main window is the
            // largest window of the ordinary layer either way.
            guard window[kCGWindowLayer as String] as? Int == 0,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 600
            else {
                continue
            }
            return frame
        }
        return nil
    }

    /// Presses the left button at `start`, moves to `end` and lets go there.
    private static func drag(from start: CGPoint, to end: CGPoint) async {
        post(.leftMouseDown, at: start)
        for step in 1...steps {
            try? await Task.sleep(for: .seconds(stepTime))
            let part = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * part, y: start.y + (end.y - start.y) * part))
        }
        try? await Task.sleep(for: .seconds(stepTime))
        post(.leftMouseUp, at: end)
    }

    /// Posts one event of the left mouse button at `point`, as the mouse itself would.
    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// The first value `probe` gives, asking again every tenth of a second; nil after `patience`.
    private static func until<Value>(_ probe: () -> Value?) async -> Value? {
        let end = Date(timeIntervalSinceNow: patience)
        while Date() < end {
            if let value = probe() {
                return value
            }
            try? await Task.sleep(for: .seconds(0.1))
        }
        return nil
    }

    /// Quits the program the way a user does, so that it writes its coverage counts.
    private static func quit(_ app: NSRunningApplication) {
        app.terminate()
        let end = Date(timeIntervalSinceNow: patience)
        while !app.isTerminated, Date() < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        if !app.isTerminated {
            print("the program did not quit; ended")
            app.forceTerminate()
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
Task { @MainActor in
    let status: Int32
    switch arguments.first {
    case "drag":
        status = await DesktopCheck.drag(Array(arguments.dropFirst()))

    default:
        print("usage: AFM UI Mouse drag <program> <profiles> <left> <right>")
        status = 2
    }
    exit(status)
}
NSApplication.shared.run()
