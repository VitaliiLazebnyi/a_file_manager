import XCTest

/// Another application a test makes the program start: quit again at the end of the test unless
/// it was running already.
@MainActor
internal struct UIOtherApplication {
    /// TextEdit, which opens text files here.
    internal static let textEdit = "com.apple.TextEdit"

    /// The application.
    internal let app: XCUIApplication
    /// Whether it ran before the test.
    private let wasRunning: Bool

    /// Whether the application runs now.
    internal var isRunning: Bool {
        app.state == .runningForeground || app.state == .runningBackground
    }

    /// The application with this bundle identifier, as it is now.
    internal init(_ bundleIdentifier: String) {
        app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        wasRunning = app.state != .notRunning
    }

    /// Waits until the application runs.
    internal func waitUntilRunning() {
        let other = self
        Wait.until("\(app) runs") { other.isRunning }
    }

    /// Quits the application the way a user does, if the test started it; says whether it is
    /// gone. An application that ran before is left running.
    internal func quit() -> Bool {
        guard !wasRunning, app.state != .notRunning else {
            return true
        }
        app.activate()
        app.typeKey("q", modifierFlags: .command)
        if app.wait(for: .notRunning, timeout: AppSession.patience) {
            return true
        }
        app.terminate()
        return false
    }
}
