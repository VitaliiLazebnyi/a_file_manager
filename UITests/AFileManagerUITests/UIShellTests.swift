import XCTest

/// The window shell's own ways to the user: its alerts, the volume list, the path bar's menu and
/// the refused command. Every alert is answered so that nothing changes; the clipboard is put
/// back.
@MainActor
internal final class UIShellTests: XCTestCase {
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

    /// Starts the program with alpha.txt and puts the cursor on it; returns the main window.
    private func start() throws -> (AppSession, XCUIElement) {
        let session = try AppSession(leftFiles: ["alpha.txt": "the first file\n"])
        running = session
        let window = try XCTUnwrap(session.launch(), "no main window")
        let alpha = window.tables.element(boundBy: 0).row(named: "alpha")
        Wait.forElement(alpha)
        window.typeKey(.downArrow, modifierFlags: [])
        Wait.until(alpha, \.isSelected, is: true)
        return (session, window)
    }

    /// Deleting for good asks, with No for Return; Esc answers No as well, and the file stays.
    internal func testEscKeepsAFileThatWasToBeDeletedForGood() throws {
        let (session, _) = try start()
        UIDesktop(session).menu("Files", "Delete Permanently…")
        let question = session.app.dialogs.firstMatch
        Wait.forElement(question)
        Check.that(question.staticTexts["Permanently delete"].exists, "the question says the file goes for good")
        Check.that(question.buttons["Yes"].exists && question.buttons["No"].exists, "the question offers Yes and No")
        session.app.typeKey(.escape, modifierFlags: [])
        Wait.until(question, \.exists, is: false)
        let file = session.left.appendingPathComponent("alpha.txt")
        Check.that(FileManager.default.fileExists(atPath: file.path), "the file is still there")
    }

    /// A message the user only reads has an OK button that ends it.
    internal func testAMessageIsReadAndClosed() throws {
        let (session, _) = try start()
        UIDesktop(session).menu("Mark", "Select Group from List…")
        let message = session.app.dialogs.firstMatch
        Wait.forElement(message)
        Check.that(
            message.staticTexts["There are no saved selection types or earlier masks yet."].exists,
            "the message says there is nothing to choose from"
        )
        message.buttons["OK"].click()
        Wait.until(message, \.exists, is: false)
    }

    /// The volume lists of both panels open from the Commands menu and show the start-up disk;
    /// Esc closes them.
    internal func testTheVolumeListsOpenFromTheMenu() throws {
        let (session, window) = try start()
        let desktop = UIDesktop(session)
        for side in ["Left Volume List", "Right Volume List"] {
            desktop.menu("Commands", side)
            let disk = window.menuItems["Macintosh HD"].firstMatch
            Wait.forElement(disk)
            session.app.typeKey(.escape, modifierFlags: [])
            Wait.until(disk, \.exists, is: false)
        }
    }

    /// Copy Path in the path bar's menu puts the folder's path on the clipboard.
    internal func testThePathBarCopiesThePath() throws {
        let (session, window) = try start()
        let clipboard = UIClipboard()
        defer { clipboard.restore() }
        let bar = window.staticTexts
            .matching(NSPredicate(format: "label == 'Current folder' AND value ENDSWITH '/left/*.*'"))
            .firstMatch
        Wait.forElement(bar)
        bar.rightClick()
        let copy = window.menuItems["Copy Path"].firstMatch
        Wait.forElement(copy)
        copy.click()
        Wait.until("the path is on the clipboard") { UIClipboard.text == session.left.path }
    }

    /// A command that cannot run now is refused: F5 on `[..]` copies nothing and asks nothing.
    internal func testARefusedCommandDoesNothing() throws {
        let (session, window) = try start()
        window.typeKey(.home, modifierFlags: [])
        Wait.until(window.tables.element(boundBy: 0).row(named: "[..]"), \.isSelected, is: true)
        window.typeKey(.F5, modifierFlags: [])
        // The refusal is a beep; the menu shows the command is not available, and no question came.
        let files = session.app.menuBars.firstMatch.menuBarItems["Files"]
        files.click()
        let copy = files.menuItems["Copy…"]
        Wait.until(copy, \.isEnabled, is: false)
        session.app.typeKey(.escape, modifierFlags: [])
        Check.that(!session.app.dialogs.firstMatch.exists, "no question was asked")
    }

    deinit {
        // Nothing to release.
    }
}
