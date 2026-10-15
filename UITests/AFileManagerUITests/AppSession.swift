import Foundation
import XCTest

/// The program under test, started with preferences and folders of its own.
///
/// A test never touches the user's settings or files:
/// - The bundle is the one `UITests/run.sh` builds with a bundle identifier of its own
///   (`bundleIdentifier`): its preferences and its folder in Application Support are not the
///   real program's. `run.sh` removes both before and after the tests. (The tests themselves
///   cannot: Xcode runs them in an App Sandbox, which writes only inside its own container.)
/// - Each session makes a new folder in the runner's temporary folder, with one folder for each
///   panel (`left`, `right`); the program is told to start there on the command line (the
///   argument domain beats whatever the preferences say). `finish` removes it.
/// - With coverage, the program writes its counts into `AFM_PROFILE_DIR`.
///
/// `run.sh` passes the paths through `xcodebuild` (`TEST_RUNNER_AFM_APP`, ...). Run from Xcode,
/// the program is the one `run.sh` built last.
@MainActor
internal final class AppSession {
    /// The bundle identifier `run.sh` gives the program under test.
    internal static let bundleIdentifier = "local.a-file-manager.uitests"

    /// How long anything the program does in response to a test may take, at most.
    ///
    /// The waits end as soon as what they wait for is there; this only bounds a test that fails.
    internal static let patience: TimeInterval = 30

    /// The title of the main window.
    private static let windowTitle = "A File Manager 0.1"

    /// The program.
    internal let app: XCUIApplication
    /// The session's folder; everything the session makes is in it.
    internal let sandbox: URL
    /// The folder the left panel starts in.
    internal let left: URL
    /// The folder the right panel starts in.
    internal let right: URL

    /// Makes the folders, with `leftFiles` (name: contents) in the left one.
    internal init(leftFiles: [String: String]) throws {
        let environment = ProcessInfo.processInfo.environment
        // UITests/AFileManagerUITests/AppSession.swift
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundle =
            environment["AFM_APP"].map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent(".build/uitest/app/A File Manager.app", isDirectory: true)
        app = XCUIApplication(url: bundle)

        let manager = FileManager.default
        sandbox = manager.temporaryDirectory.appendingPathComponent("afm-uitest-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        left = sandbox.appendingPathComponent("left", isDirectory: true)
        right = sandbox.appendingPathComponent("right", isDirectory: true)
        try manager.createDirectory(at: left, withIntermediateDirectories: true)
        try manager.createDirectory(at: right, withIntermediateDirectories: true)
        for (name, contents) in leftFiles {
            try Data(contents.utf8).write(to: left.appendingPathComponent(name))
        }

        app.launchArguments = [
            "-left.tabs", try Self.tabs(at: left), "-right.tabs", try Self.tabs(at: right),
            // No windows brought back from an earlier run.
            "-ApplePersistenceIgnoreState", "YES"
        ]
        if let profiles = environment["AFM_PROFILE_DIR"] {
            // %p: one file for each run of the program.
            app.launchEnvironment["LLVM_PROFILE_FILE"] = profiles + "/ui-%p.profraw"
        }
    }

    /// The tabs of a panel as the program keeps them (`PanelTabs.State`), in the property-list
    /// form the argument domain reads: `<hex bytes>` is data.
    private static func tabs(at folder: URL) throws -> String {
        let tab: [String: Any] = [
            "location": folder.absoluteString, "sortKey": 0, "descending": false, "showHidden": false
        ]
        let json = try JSONSerialization.data(withJSONObject: ["tabs": [tab], "active": 0])
        return "<" + json.map { String(format: "%02x", $0) }.joined() + ">"
    }

    /// Starts the program and returns its main window, once it is there (nil if it never came).
    internal func launch() -> XCUIElement? {
        app.launch()
        let window = app.windows[Self.windowTitle]
        return window.waitForExistence(timeout: Self.patience) ? window : nil
    }

    /// Quits the program and removes the session's folder; says whether the program quit.
    ///
    /// The program is quit the way a user does, so it writes its coverage counts; one that has
    /// not gone after `patience` is ended.
    internal func finish() -> Bool {
        defer { try? FileManager.default.removeItem(at: sandbox) }
        guard app.state == .runningForeground || app.state == .runningBackground else {
            return true
        }
        app.typeKey("q", modifierFlags: .command)
        if app.wait(for: .notRunning, timeout: Self.patience) {
            return true
        }
        app.terminate()
        return false
    }

    deinit {
        // Nothing to release.
    }
}
