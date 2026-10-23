import XCTest

/// The System Tools' ways out of the program: an application started from the command line or
/// chosen to open a file, the clipboard, printing, minimizing and quitting.
///
/// TextEdit is quit again, the clipboard put back, the print sheet cancelled and the window brought
/// back.
@MainActor
internal final class UISystemToolsTests: XCTestCase {
    /// The program of the running test, once started.
    private var running: AppSession?
    /// TextEdit, when a test may make the program start it.
    private var textEdit: UIOtherApplication?

    /// A test stops at its first failure: what follows depends on what failed.
    override internal func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    /// Quits TextEdit if a test started it, then the program, and removes the test's folders.
    override internal func tearDown() async throws {
        if let textEdit, !textEdit.quit() {
            XCTFail("TextEdit did not quit")
        }
        if let running, !running.finish() {
            XCTFail("the program did not quit")
        }
        (running, textEdit) = (nil, nil)
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

    /// The System Information dialog is a form; its Copy button puts what it says on the
    /// clipboard.
    internal func testSystemInformationCanBeCopied() throws {
        let (session, _) = try start()
        let clipboard = UIClipboard()
        defer { clipboard.restore() }
        UIDesktop(session).menu("Commands", "More", "System Information…")
        let dialog = session.app.dialogs.firstMatch
        Wait.forElement(dialog)
        Check.that(dialog.staticTexts["System Information"].exists, "the dialog is called System Information")
        dialog.buttons["Copy"].click()
        Wait.until(dialog, \.exists, is: false)
        Wait.until("the information is on the clipboard") { UIClipboard.text?.contains("macOS version") == true }
    }

    /// A name typed on the command line that is an application starts it.
    internal func testAnApplicationTypedOnTheCommandLineStarts() throws {
        let other = UIOtherApplication(UIOtherApplication.textEdit)
        textEdit = other
        let (_, window) = try start()
        let line = window.comboBoxes["Command line"]
        line.click()
        line.typeText("TextEdit\n")
        other.waitUntilRunning()
    }

    /// An application typed with a file opens the file.
    internal func testAnApplicationTypedWithAFileOpensIt() throws {
        let other = UIOtherApplication(UIOtherApplication.textEdit)
        textEdit = other
        let (_, window) = try start()
        let line = window.comboBoxes["Command line"]
        line.click()
        line.typeText("TextEdit.app alpha.txt\n")
        other.waitUntilRunning()
        Wait.forElement(other.app.windows["alpha.txt"])
    }

    /// The System Tools' Open With… lists the applications for the file; Open hands it to the
    /// first, TextEdit.
    internal func testOpenWithHandsTheFileToTheChosenApplication() throws {
        let other = UIOtherApplication(UIOtherApplication.textEdit)
        textEdit = other
        let (session, _) = try start()
        UIDesktop(session).menu("Files", item: "Open With…", number: 0)
        let choice = session.app.dialogs.firstMatch
        Wait.forElement(choice)
        Check.that(choice.staticTexts["Open alpha.txt with:"].exists, "the question names the file")
        choice.buttons["Open"].click()
        other.waitUntilRunning()
        Wait.forElement(other.app.windows["alpha.txt"])
    }

    /// Print File List… asks how to print the list, then shows the system's print sheet,
    /// cancelled here.
    internal func testTheFileListPrintsThroughThePrintSheet() throws {
        let (session, window) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Files", "More", "Print File List…")
        let form = session.app.dialogs.firstMatch
        Wait.forElement(form)
        Check.that(form.staticTexts["Print directory"].exists, "the form is the one of printing the list")
        form.buttons["Print"].click()
        Wait.forElement(window.sheets.firstMatch)
        desktop.cancelPanel("the print sheet")
    }

    /// Minimize (run from Choose Command) takes the main window off the screen; the Window menu
    /// brings it back.
    internal func testMinimizeTakesTheWindowOffTheScreen() throws {
        let (session, window) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Configuration", "Choose Command…")
        let chooser = desktop.window(titled: "Choose Command")
        Wait.forElement(chooser)
        // Typing only narrows the list; Return runs the one command left, which is selected.
        let filter = chooser.searchFields.firstMatch
        filter.typeText("cm_Minimize")
        let rows = chooser.tables.firstMatch.tableRows
        Wait.until("only Minimize is listed") { rows.count == 1 }
        Check.that(rows.firstMatch.staticTexts["cm_Minimize"].exists && window.isHittable, "nothing ran yet")
        filter.typeText("\n")
        Wait.until("the main window is minimized") { !window.isHittable }
        desktop.menu("Window", "A File Manager 0.1")
        Wait.until("the main window is back") { window.isHittable }
    }

    /// Files › More › Quit ends the program.
    internal func testQuitEndsTheProgram() throws {
        let (session, _) = try start()
        UIDesktop(session).menu("Files", "More", "Quit")
        Check.that(session.app.wait(for: .notRunning, timeout: AppSession.patience), "the program has quit")
    }

    deinit {
        // Nothing to release.
    }
}
