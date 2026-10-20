import XCTest

/// The configuration's ways to the system: the command chooser run as a modal dialog, the key
/// recorder, the settings file panels, the About panel and saving the window positions. Every
/// dialog is cancelled: no setting changes.
@MainActor
internal final class UIConfigurationTests: XCTestCase {
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

    /// Starts the program; returns it and its main window.
    private func start() throws -> (AppSession, XCUIElement) {
        let session = try AppSession(leftFiles: ["alpha.txt": "a"])
        running = session
        let window = try XCTUnwrap(session.launch(), "no main window")
        Wait.forElement(window.tables.element(boundBy: 0).row(named: "alpha"))
        return (session, window)
    }

    /// Add Command… of the button-bar editor runs the command chooser as a modal dialog: a double
    /// click below its rows chooses nothing, OK chooses the command left by the filter, and the
    /// editor lists it. Cancel keeps the button bar as it was.
    internal func testTheButtonBarEditorChoosesACommandInAModalChooser() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Configuration", "Button Bar…")
        let options = desktop.window(titled: "Options")
        Wait.forElement(options)
        options.buttons["Add Command…"].click()
        let chooser = desktop.window(titled: "Choose Command")
        Wait.forElement(chooser)
        let filter = chooser.searchFields.firstMatch
        filter.typeText("cm_SysInfo")
        let list = chooser.tables.firstMatch
        Wait.until("only System Information is listed") { list.tableRows.count == 1 }
        // A double click below the rows chooses nothing (and leaves no row selected).
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).doubleClick()
        Check.that(chooser.exists, "a double click on no row chooses nothing")
        list.tableRows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        chooser.buttons["OK"].click()
        Wait.until(chooser, \.exists, is: false)
        Wait.forElement(options.tables.staticTexts["cm_SysInfo"])
        options.buttons["Cancel"].click()
        Wait.until(options, \.exists, is: false)
    }

    /// Set Shortcut… waits for the next key; Esc gives up waiting.
    internal func testSetShortcutWaitsForAKeyAndEscGivesUp() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Configuration", "Redefine Hotkeys…")
        let options = desktop.window(titled: "Options")
        Wait.forElement(options)
        let keys = options.tables.element(boundBy: 1)
        keys.tableRows.firstMatch.click()
        options.buttons["Set Shortcut…"].click()
        let waiting = options.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Press the new shortcut'"))
        Wait.forElement(waiting.firstMatch)
        options.typeKey(.escape, modifierFlags: [])
        Wait.until(waiting.firstMatch, \.exists, is: false)
        options.buttons["Cancel"].click()
        Wait.until(options, \.exists, is: false)
    }

    /// Export Settings… asks what to export, then where, in the system's save panel; Import
    /// Settings… asks for the file in its open panel. Both are cancelled.
    internal func testExportAndImportAskForTheSettingsFile() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Configuration", "Export Settings…")
        let form = session.app.dialogs.firstMatch
        Wait.forElement(form)
        form.buttons["Export…"].click()
        Wait.until(form.buttons["Export…"], \.exists, is: false)
        desktop.cancelPanel("the save panel of the export")
        desktop.menu("Configuration", "Import Settings…")
        desktop.cancelPanel("the open panel of the import")
    }

    /// About shows the system's About panel with the program's name; Save Position keeps the
    /// windows where they are.
    internal func testAboutShowsTheAboutPanelAndSavePositionKeepsTheWindow() throws {
        let (session, window) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Help", "About A File Manager")
        let version = session.app.staticTexts
            .matching(
                NSPredicate(format: "label BEGINSWITH 'Version ' OR value BEGINSWITH 'Version '")
            )
            .firstMatch
        Wait.forElement(version)
        // The panel's close button: the rightmost of the close buttons above its text.
        let closers = session.app.buttons.matching(identifier: "_XCUI:CloseWindow")
        let text = version.frame
        let close = (0..<closers.count).map { closers.element(boundBy: $0) }
            .filter { $0.frame.maxY < text.minY && $0.frame.minX > text.minX - 200 }
            .max { $0.frame.minX < $1.frame.minX }
        try XCTUnwrap(close, "the About panel has a close button").click()
        Wait.until(version, \.exists, is: false)
        let frame = window.frame
        desktop.menu("Configuration", "Save Position")
        Check.that(window.frame == frame, "the window stays where it was")
    }

    deinit {
        // Nothing to release.
    }
}
