import XCTest

/// The panels and the window under the mouse and the keyboard as a user has them: clicks on a
/// row, the bars' buttons, the command line and its history, a window that starts in full
/// screen, and a new name taken from the clipboard.
@MainActor
internal final class UIPanelTests: XCTestCase {
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

    /// A session with alpha.txt and the folder docs in the left panel.
    private func session() throws -> AppSession {
        let session = try AppSession(leftFiles: ["alpha.txt": "a"])
        try FileManager.default.createDirectory(
            at: session.left.appendingPathComponent("docs"),
            withIntermediateDirectories: false
        )
        running = session
        return session
    }

    /// Starts the program of `session`; returns its main window once the left list is there.
    private func start(_ session: AppSession) throws -> XCUIElement {
        let window = try XCTUnwrap(session.launch(), "no main window")
        Wait.forElement(window.tables.element(boundBy: 0).row(named: "alpha"))
        return window
    }

    /// The button F7 NewFolder asks for the name; `[X]` in it stands for the text on the
    /// clipboard, which becomes the folder's name.
    internal func testANewFolderTakesItsNameFromTheClipboard() throws {
        let session = try session()
        let window = try start(session)
        let clipboard = UIClipboard()
        defer { clipboard.restore() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("from the clipboard", forType: .string)

        window.buttons["F7 NewFolder"].click()
        let question = session.app.dialogs.firstMatch
        Wait.forElement(question)
        let name = question.textFields.firstMatch
        name.typeKey("a", modifierFlags: .command)
        // `<` starts a name with placeholders.
        name.typeText("<[X]\n")
        let made = session.left.appendingPathComponent("from the clipboard")
        Wait.until("the folder is made") { FileManager.default.fileExists(atPath: made.path) }
        Wait.forElement(window.tables.element(boundBy: 0).row(named: "[from the clipboard]"))
    }

    /// A click on a row puts the cursor there; a second, unhurried click on it starts renaming:
    /// the row stops showing the name, the box in its place takes what is typed, and Enter
    /// renames the folder.
    ///
    /// The box itself is not offered to the accessibility interface (it lies on the table, which
    /// tells only of its rows), so the test sees the row and the folder.
    internal func testAClickMovesTheCursorAndASecondClickRenames() throws {
        let session = try session()
        let window = try start(session)
        let list = window.tables.element(boundBy: 0)
        let docs = list.row(named: "[docs]")
        docs.click()
        Wait.until(docs, \.isSelected, is: true)
        Check.that(docs.exists, "one click renames nothing")
        // Long enough apart not to be a double click: the rename waits for that time to pass.
        docs.click()
        Wait.until(docs, \.exists, is: false)
        window.typeKey("a", modifierFlags: .command)
        window.typeText("papers\n")
        let renamed = session.left.appendingPathComponent("papers")
        Wait.until("the folder is renamed") { FileManager.default.fileExists(atPath: renamed.path) }
        Wait.forElement(list.row(named: "[papers]"))
    }

    /// A line typed on the command line runs and goes into its history; the history opens from
    /// the menu, its keys are its own while it is open, and Esc closes it.
    internal func testTheCommandLineKeepsItsHistory() throws {
        let session = try session()
        let window = try start(session)
        let line = window.comboBoxes["Command line"]
        line.click()
        line.typeText("true\n")
        UIDesktop(session).menu("Commands", "More", "Command Line History")
        // The list of earlier lines is a window of its own, below the line.
        let earlier = session.app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == 'true' OR label == 'true' OR title == 'true'"))
            .firstMatch
        Wait.forElement(earlier)
        line.typeKey(.downArrow, modifierFlags: [])
        line.typeKey(.escape, modifierFlags: [])
        Wait.until(earlier, \.exists, is: false)
    }

    /// A plain click on a button of the button bar runs its command (Reread Source: the list
    /// stays as it is).
    internal func testAButtonOfTheButtonBarRunsItsCommand() throws {
        let session = try session()
        let window = try start(session)
        window.checkBoxes["cm_RereadSource"].click()
        Wait.forElement(window.tables.element(boundBy: 0).row(named: "alpha"))
        Check.that(window.tables.element(boundBy: 0).tableRows.count == 3, "[..], docs and alpha")
    }

    /// A window left in full screen starts in full screen; leaving it brings the window back.
    internal func testTheWindowStartsInFullScreenWhenItWasLeftThere() throws {
        let session = try session()
        try session.pin("window.fullScreen", to: true)
        let window = try start(session)
        Wait.until("the window fills the screen") { window.frame.minY == 0 }
        window.typeKey("f", modifierFlags: [.command, .control])
        Wait.until("the window has left full screen") { window.frame.minY > 0 }
    }

    deinit {
        // Nothing to release.
    }
}
