import XCTest

/// The main window as it comes up, and moving around in it with the keyboard.
@MainActor
internal final class MainWindowTests: XCTestCase {
    /// The program of the running test, once started.
    private var running: AppSession?

    /// A test stops at its first failure: what follows depends on what failed.
    override internal func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    /// Quits the program and removes the test's folders.
    override internal func tearDown() async throws {
        if let running, !running.finish() {
            XCTFail("the program did not quit")
        }
        running = nil
        try await super.tearDown()
    }

    /// Two file lists side by side, each showing its own folder, and the function key bar.
    internal func testTheMainWindowShowsTwoPanelsWithTheirFolders() throws {
        let session = try AppSession(leftFiles: ["alpha.txt": "a", "beta.txt": "b"])
        running = session
        let window = try XCTUnwrap(session.launch(), "no main window")
        let panels = window.tables
        Wait.until("there are two file lists") { panels.count == 2 }
        let left = panels.element(boundBy: 0)
        let right = panels.element(boundBy: 1)
        Wait.forElement(left.row(named: "alpha"))
        Check.that(left.row(named: "beta").exists, "beta is listed")
        Check.that(left.tableRows.count == 3, "[..], alpha and beta, nothing else")
        // The right panel's folder is empty: only the way up is listed.
        Wait.forElement(right.row(named: "[..]"))
        Check.that(right.tableRows.count == 1, "the right panel lists [..] alone")
        Check.that(window.buttons["F5 Copy"].exists, "the function key bar shows F5 Copy")
    }

    /// The cursor starts on the first row; the arrow keys and Home move it.
    internal func testTheArrowKeysMoveTheCursor() throws {
        let session = try AppSession(leftFiles: ["alpha.txt": "a", "beta.txt": "b"])
        running = session
        let window = try XCTUnwrap(session.launch(), "no main window")
        let left = window.tables.element(boundBy: 0)
        let parent = left.row(named: "[..]")
        let alpha = left.row(named: "alpha")
        let beta = left.row(named: "beta")
        Wait.forElement(beta)
        Wait.until(parent, \.isSelected, is: true)

        window.typeKey(.downArrow, modifierFlags: [])
        Wait.until(alpha, \.isSelected, is: true)
        Check.that(!parent.isSelected, "the cursor left [..]")

        window.typeKey(.downArrow, modifierFlags: [])
        Wait.until(beta, \.isSelected, is: true)
        Check.that(!alpha.isSelected, "the cursor left alpha")

        window.typeKey(.upArrow, modifierFlags: [])
        Wait.until(alpha, \.isSelected, is: true)

        window.typeKey(.home, modifierFlags: [])
        Wait.until(parent, \.isSelected, is: true)
    }
}
