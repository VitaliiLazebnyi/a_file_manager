import XCTest

/// The hotlist editor, the directory tree, Find Files and the Multi-Rename tool, where they hand
/// over to the system: a modal editor, the beep of a search that finds nothing, open panels as
/// sheets. Everything is cancelled or closed.
@MainActor
internal final class UIToolWindowsTests: XCTestCase {
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

    /// Starts the program with alpha.txt, the cursor on it; returns it and its main window.
    private func start() throws -> (AppSession, XCUIElement) {
        let session = try AppSession(leftFiles: ["alpha.txt": "a"])
        running = session
        let window = try XCTUnwrap(session.launch(), "no main window")
        let alpha = window.tables.element(boundBy: 0).row(named: "alpha")
        Wait.forElement(alpha)
        window.typeKey(.downArrow, modifierFlags: [])
        Wait.until(alpha, \.isSelected, is: true)
        return (session, window)
    }

    /// Configure… of the hotlist opens its editor as a modal window; Cancel ends it, and the
    /// program takes keys again.
    internal func testTheHotlistEditorIsAModalWindow() throws {
        let (session, window) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Commands", "Directory Hotlist…")
        let list = session.app.dialogs.firstMatch
        Wait.forElement(list)
        let configure = list.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Configure'")).firstMatch
        Wait.forElement(configure)
        configure.click()
        list.buttons["Go"].click()
        let editor = desktop.window(titled: "Change Directory Menu")
        Wait.forElement(editor)
        editor.buttons["Cancel"].click()
        Wait.until(editor, \.exists, is: false)
        window.typeKey(.home, modifierFlags: [])
        Wait.until(window.tables.element(boundBy: 0).row(named: "[..]"), \.isSelected, is: true)
    }

    /// The tree's quick search beeps when no folder matches; Cancel closes the tree.
    internal func testTheTreeBeepsWhenNothingMatches() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Commands", "Directory Tree…")
        let tree = desktop.window(titled: "Directory Tree")
        Wait.forElement(tree)
        let search = tree.textFields.firstMatch
        search.click()
        search.typeText("zq9xw7nothing")
        Check.that(tree.exists, "the tree stays open")
        tree.buttons["Cancel"].click()
        Wait.until(tree, \.exists, is: false)
    }

    /// Find Files' `>>` asks for the folders to search in a sheet (cancelled).
    internal func testFindFilesAsksForTheFoldersInASheet() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Files", "More", "Find Files…")
        let find = desktop.window(titled: "Find Files")
        Wait.forElement(find)
        find.buttons[">>"].click()
        desktop.cancelPanel("the sheet for the folders")
        find.buttons["Close"].click()
        Wait.until(find, \.exists, is: false)
    }

    /// The Multi-Rename tool's Load names from file… asks for the file in a sheet (cancelled).
    internal func testMultiRenameAsksForTheNamesFileInASheet() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Files", "More", "Multi-Rename Tool…")
        let tool = desktop.window(titled: "Multi-Rename Tool")
        Wait.forElement(tool)
        tool.menuButtons["F10 Names"].click()
        let load = tool.menuItems["Load names from file…"].firstMatch
        Wait.forElement(load)
        load.click()
        desktop.cancelPanel("the sheet for the names file")
        tool.buttons["Close"].click()
        Wait.until(tool, \.exists, is: false)
    }

    deinit {
        // Nothing to release.
    }
}
