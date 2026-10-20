import AppKit

/// The checks, run on the main thread while the run loop turns.
internal enum DesktopCheck {
    /// The title of the program's main window.
    private static let windowTitle = "A File Manager 0.1"
    /// How long anything may take, at most (as `AppSession.patience`).
    private static let patience: TimeInterval = 30
    /// The steps of a drag, and the time between two of them: a hand moves the mouse in steps,
    /// and the system starts a drag only once the pressed mouse has moved for a moment.
    private static let steps = 30
    private static let stepTime: TimeInterval = 0.02

    /// The keys of the modifiers, as the keyboard sends them (Cmd, Shift, Opt, Ctrl).
    private static let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59)
    ]

    /// The drag check; its exit status.
    internal static func drag(_ arguments: [String]) async -> Int32 {
        guard arguments.count == 4 else {
            print("usage: drag <program> <profiles> <left> <right>")
            return 2
        }
        let (program, profiles) = (URL(fileURLWithPath: arguments[0]), arguments[1])
        let left = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let right = URL(fileURLWithPath: arguments[3], isDirectory: true)
        do {
            let settings = try ProgramArguments.drag(left: left, right: right)
            guard let (app, frame) = await start(program, profiles: profiles, arguments: settings) else {
                return 1
            }
            defer { quit(app) }
            // The middle of each panel: a file of the left one's thumbnails, the right one's list.
            let start = CGPoint(x: frame.minX + frame.width * 0.25, y: frame.midY)
            let target = CGPoint(x: frame.minX + frame.width * 0.75, y: frame.midY)
            // The helper cannot see when the left list has been read: a drag that starts before
            // finds no file under the mouse, and the next one is made a moment later.
            var arrived: String?
            let end = Date(timeIntervalSinceNow: patience)
            while arrived == nil, Date() < end {
                await drag(from: start, to: target)
                arrived = await until(seconds: 3) {
                    ((try? FileManager.default.contentsOfDirectory(atPath: right.path)) ?? []).first
                }
            }
            print(arrived.map { "a file arrived in \(right.path): \($0)" } ?? "nothing arrived in \(right.path)")
            return arrived == nil ? 1 : 0
        } catch {
            print("the program did not start: \(error)")
            return 1
        }
    }

    /// The Finder Info check; its exit status.
    ///
    /// The program asks Finder for the Info window of the file in `folder`, which a new Finder
    /// window shows; it is closed again.
    internal static func finderInfo(_ arguments: [String]) async -> Int32 {
        guard arguments.count == 3 else {
            print("usage: finder-info <program> <profiles> <folder>")
            return 2
        }
        let (program, profiles) = (URL(fileURLWithPath: arguments[0]), arguments[1])
        let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else {
            print("Finder is not running")
            return 1
        }
        do {
            let settings = try ProgramArguments.finderInfo(folder: folder)
            guard let (app, _) = await start(program, profiles: profiles, arguments: settings) else {
                return 1
            }
            defer { quit(app) }
            let before = windows(of: finder.processIdentifier)
            // [..], then the file; then Finder Info (keyBindings).
            press(125)
            press(34, [.maskControl, .maskAlternate, .maskShift])
            let shown = await until { () -> Int? in
                let count = windows(of: finder.processIdentifier)
                return count > before ? count : nil
            }
            guard shown != nil else {
                print("Finder showed no new window")
                return 1
            }
            print("Finder showed the Info window")
            // Closed with Cmd+W once Finder has the keyboard. A press that came too early went
            // nowhere and is made again, but only after a second without the window going: one
            // press too many would close another of Finder's windows.
            finder.activate()
            _ = await until { finder.isActive ? finder.processIdentifier : nil }
            var closed: Int?
            let end = Date(timeIntervalSinceNow: patience)
            while closed == nil, Date() < end {
                press(13, .maskCommand)
                closed = await until(seconds: 1) { () -> Int? in
                    let count = windows(of: finder.processIdentifier)
                    return count <= before ? count : nil
                }
            }
            if closed == nil {
                print("the Info window stayed open")
                return 1
            }
            return 0
        } catch {
            print("the program did not start: \(error)")
            return 1
        }
    }

    /// Starts the program with `arguments` (its coverage counts go to `profiles`) and brings it
    /// to the front; the program and its main window's frame, nil (said why) when that failed.
    private static func start(_ program: URL, profiles: String, arguments: [String]) async -> (
        NSRunningApplication, CGRect
    )? {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            print("not allowed to post events: Privacy & Security › Accessibility")
            return nil
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ["LLVM_PROFILE_FILE": profiles + "/ui-%p.profraw"]
        configuration.arguments = arguments
        guard let app = try? await NSWorkspace.shared.openApplication(at: program, configuration: configuration) else {
            print("the program did not start")
            return nil
        }
        guard let frame = await until({ mainWindowFrame(of: app.processIdentifier) }) else {
            print("the program showed no main window")
            quit(app)
            return nil
        }
        app.activate()
        guard await until({ app.isActive ? app.processIdentifier : nil }) != nil else {
            print("the program did not come to the front")
            quit(app)
            return nil
        }
        return (app, frame)
    }

    /// The windows of the ordinary layer of `pid` on screen.
    private static func windows(of pid: pid_t) -> Int {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return
            windows.filter { window in
                window[kCGWindowOwnerPID as String] as? pid_t == pid && window[kCGWindowLayer as String] as? Int == 0
            }
            .count
    }

    /// Presses and lets go the key `code` with `flags`, as the keyboard itself would: each
    /// modifier key goes down before and up after, so that none stays held for the system (a
    /// key event that only carries a modifier's flag leaves it held).
    private static func press(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let modifiers = modifierKeys.filter { flags.contains($0.0) }
        var held: CGEventFlags = []
        for (flag, key) in modifiers {
            held.insert(flag)
            post(key: key, down: true, flags: held, modifier: true)
        }
        post(key: code, down: true, flags: held, modifier: false)
        post(key: code, down: false, flags: held, modifier: false)
        for (flag, key) in modifiers.reversed() {
            held.remove(flag)
            post(key: key, down: false, flags: held, modifier: true)
        }
    }

    /// Lets go every modifier key, whatever held it; each check ends with it.
    internal static func releaseModifiers() {
        for (_, key) in modifierKeys {
            post(key: key, down: false, flags: [], modifier: true)
        }
    }

    /// Posts one key event; a modifier's own key changes the flags (`flagsChanged`).
    private static func post(key: CGKeyCode, down: Bool, flags: CGEventFlags, modifier: Bool) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
        if modifier {
            event?.type = .flagsChanged
        }
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    /// The frame of the program's main window, in screen points from the top left; nil while
    /// it is not on screen.
    private static func mainWindowFrame(of pid: pid_t) -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where window[kCGWindowOwnerPID as String] as? pid_t == pid {
            // The title needs the permission to record the screen; the main window is the
            // largest window of the ordinary layer either way.
            guard window[kCGWindowLayer as String] as? Int == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width > 600
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
            let point = CGPoint(x: start.x + (end.x - start.x) * part, y: start.y + (end.y - start.y) * part)
            post(.leftMouseDragged, at: point)
        }
        try? await Task.sleep(for: .seconds(stepTime))
        post(.leftMouseUp, at: end)
    }

    /// Posts one event of the left mouse button at `point`, as the mouse itself would.
    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// The first value `probe` gives, asking again every tenth of a second; nil after `seconds`.
    private static func until<Value>(seconds: TimeInterval = patience, _ probe: () -> Value?) async -> Value? {
        let end = Date(timeIntervalSinceNow: seconds)
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
