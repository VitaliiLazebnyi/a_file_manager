import XCTest

/// What the system's open and save panels give back when the user chooses: the file that
/// Compare By Content and the folder that Synchronize Directories ask for in a sheet, the file
/// the Lister saves a copy to, and the file the settings are exported to.
///
/// Also the beep of a configuration button that has nothing to act on, and a double click on a
/// synchronize action.
@MainActor
internal final class LastSheetTests: XCTestCase {
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

    /// Starts the program with two files that differ, the cursor on the first; returns it and
    /// its main window.
    private func start() throws -> (AppSession, XCUIElement) {
        let session = try AppSession(leftFiles: ["alpha.txt": "one\nsame\n", "beta.txt": "two\nsame\n"])
        running = session
        let window = try XCTUnwrap(session.launch(), "no main window")
        let alpha = window.tables.element(boundBy: 0).row(named: "alpha")
        Wait.forElement(alpha)
        window.typeKey(.downArrow, modifierFlags: [])
        Wait.until(alpha, \.isSelected, is: true)
        return (session, window)
    }

    /// The file chosen in the sheet of `>>` is the second file of the comparison.
    internal func testCompareTakesTheFileChosenInItsSheet() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Files", "More", "Compare By Content…")
        let compare = desktop.window(titled: "Compare contents")
        Wait.forElement(compare)
        compare.buttons.matching(NSPredicate(format: "title == '>>'")).element(boundBy: 1).click()
        let beta = session.left.appendingPathComponent("beta.txt").path
        desktop.choose(beta, in: "the sheet for the second file")
        Wait.until("the second file is beta.txt") { compare.textFields.element(boundBy: 1).value as? String == beta }
        compare.typeKey("w", modifierFlags: .command)
        Wait.until(compare, \.exists, is: false)
    }

    /// The folder chosen in the sheet of the left `>>` is the left folder of the comparison; a
    /// double click on a row's action changes the action once and compares no contents.
    internal func testSynchronizeTakesTheFolderChosenInItsSheet() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Commands", "More", "Synchronize Dirs…")
        let sync = desktop.window(titled: "Synchronize directories")
        Wait.forElement(sync)
        let left = sync.textFields.element(boundBy: 0)
        left.click()
        left.typeKey("a", modifierFlags: .command)
        left.typeKey(.delete, modifierFlags: [])
        Wait.until("the left folder is empty") { (left.value as? String)?.isEmpty != false }
        sync.buttons.matching(NSPredicate(format: "title == '>>'")).element(boundBy: 0).click()
        desktop.choose(session.left.path, in: "the sheet for the left folder")
        Wait.until("the left folder is the chosen one") {
            (left.value as? String)?.hasPrefix(session.left.path) == true
        }

        sync.buttons["Compare"].click()
        let row = sync.tables.firstMatch.tableRows.firstMatch
        Wait.forElement(row)
        let copyRight = row.staticTexts["→"]
        Wait.forElement(copyRight)
        copyRight.doubleClick()
        Wait.until(copyRight, \.exists, is: false)
        Check.that(!desktop.window(titled: "Compare contents").exists, "no contents were compared")
        sync.buttons["Close"].click()
        Wait.until(sync, \.exists, is: false)
    }

    /// Save as… of the Lister writes the file where the save panel says.
    internal func testTheListerSavesACopyWhereTheSavePanelSays() throws {
        let (session, window) = try start()
        window.typeKey(.F3, modifierFlags: [])
        let desktop = UIDesktop(session)
        let lister = desktop.window(titled: "Lister")
        Wait.forElement(lister)
        let file = lister.menuButtons["File"]
        file.click()
        let saveAs = file.menuItems
            .matching(NSPredicate(format: "title == 'Save as…' OR title BEGINSWITH 'Save as…\t'"))
            .firstMatch
        Wait.forElement(saveAs)
        saveAs.click()
        desktop.choose(session.right.path, in: "the save panel")
        let copy = session.right.appendingPathComponent("alpha.txt")
        Wait.until("the copy is saved") { (try? String(contentsOf: copy, encoding: .utf8)) == "one\nsame\n" }
        lister.typeKey("q", modifierFlags: [])
        Wait.until(lister, \.exists, is: false)
    }

    /// Export Settings… writes the settings into the file the save panel says.
    internal func testTheSettingsAreExportedWhereTheSavePanelSays() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Configuration", "Export Settings…")
        let form = session.app.dialogs.firstMatch
        Wait.forElement(form)
        form.buttons["Export…"].click()
        Wait.until(form.buttons["Export…"], \.exists, is: false)
        desktop.choose(session.right.path, in: "the save panel of the export")
        let file = session.right.appendingPathComponent("A File Manager Settings.json")
        Wait.until("the settings are written") {
            (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
        }
    }

    /// A double click on a command in the modal chooser of Add Command… chooses it: the
    /// button-bar editor lists it.
    ///
    /// Cancel keeps the button bar as it was.
    internal func testADoubleClickOnACommandChoosesIt() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Configuration", "Button Bar…")
        let options = desktop.window(titled: "Options")
        Wait.forElement(options)
        options.buttons["Add Command…"].click()
        let chooser = desktop.window(titled: "Choose Command")
        Wait.forElement(chooser)
        chooser.searchFields.firstMatch.typeText("cm_SysInfo")
        let rows = chooser.tables.firstMatch.tableRows
        Wait.until("only System Information is listed") { rows.count == 1 }
        rows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        Wait.until(chooser, \.exists, is: false)
        Wait.forElement(options.tables.staticTexts["cm_SysInfo"])
        options.buttons["Cancel"].click()
        Wait.until(options, \.exists, is: false)
    }

    /// Set Shortcut… with no command chosen only beeps: it waits for no key.
    internal func testSetShortcutWithoutACommandWaitsForNoKey() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Configuration", "Redefine Hotkeys…")
        let options = desktop.window(titled: "Options")
        Wait.forElement(options)
        let keys = options.tables.element(boundBy: 1)
        Wait.forElement(keys.tableRows.firstMatch)
        Check.that(!keys.tableRows.firstMatch.isSelected, "no command is chosen")
        options.buttons["Set Shortcut…"].click()
        let waiting = options.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Press the new shortcut'"))
        Check.that(!waiting.firstMatch.exists, "nothing waits for a key")
        options.buttons["Cancel"].click()
        Wait.until(options, \.exists, is: false)
    }

    deinit {
        // Nothing to release.
    }
}
