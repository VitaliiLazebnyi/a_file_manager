import XCTest

/// The windows of Compare By Content and Synchronize Directories and their ways to the system:
/// the file and folder panels as sheets, the font panel, the beep at the last difference, the
/// menu of the saved comparisons. Everything is cancelled or closed; nothing is synchronized.
@MainActor
internal final class UICompareSyncTests: XCTestCase {
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

    /// Starts the program with two files that differ in their first line, the cursor on the
    /// first; returns it and its main window.
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

    /// The compare window: `>>` asks for a file in a sheet (cancelled), Font… shows the font
    /// panel (closed); after the one difference of the two files there is none further.
    internal func testCompareAsksForAFileShowsTheFontsAndFindsTheDifference() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Files", "More", "Compare By Content…")
        let compare = desktop.window(titled: "Compare contents")
        Wait.forElement(compare)

        compare.buttons.matching(NSPredicate(format: "title == '>>'")).element(boundBy: 1).click()
        desktop.cancelPanel("the sheet for the second file")

        compare.buttons["Font…"].click()
        let fonts = desktop.window(titled: "Fonts")
        Wait.forElement(fonts)
        fonts.buttons["_XCUI:CloseWindow"].click()
        Wait.until(fonts, \.exists, is: false)

        let second = compare.textFields.element(boundBy: 1)
        second.click()
        second.typeText(session.left.appendingPathComponent("beta.txt").path)
        compare.buttons["Compare"].click()
        let next = compare.buttons["Next difference"]
        Wait.until(next, \.isEnabled, is: true)
        next.click()
        // The one difference was the last: the next press only beeps, and the window stays.
        next.click()
        Check.that(compare.exists, "the window is still there")
        compare.typeKey("w", modifierFlags: .command)
        Wait.until(compare, \.exists, is: false)
    }

    /// The synchronize window: `>>` asks for a folder in a sheet (cancelled), F2 opens the menu
    /// of saved comparisons (closed with Esc); after Compare a click on a row's action changes
    /// it, a click elsewhere in the row does not.
    internal func testSynchronizeAsksForAFolderShowsItsMenuAndChangesAnAction() throws {
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Commands", "More", "Synchronize Dirs…")
        let sync = desktop.window(titled: "Synchronize directories")
        Wait.forElement(sync)

        sync.buttons.matching(NSPredicate(format: "title == '>>'")).element(boundBy: 0).click()
        desktop.cancelPanel("the sheet for the left folder")

        // F2 is a key of the list.
        sync.tables.firstMatch.click()
        sync.typeKey(.F2, modifierFlags: [])
        let sets = sync.menuButtons["★"].menuItems.firstMatch
        Wait.forElement(sets)
        session.app.typeKey(.escape, modifierFlags: [])
        Wait.until(sets, \.exists, is: false)

        sync.buttons["Compare"].click()
        let row = sync.tables.firstMatch.tableRows.firstMatch
        Wait.forElement(row)
        let copyRight = row.staticTexts["→"]
        Wait.forElement(copyRight)
        row.staticTexts["alpha.txt"].firstMatch.click()
        Check.that(copyRight.exists, "a click on the name leaves the action")
        copyRight.click()
        Wait.until(copyRight, \.exists, is: false)
        sync.buttons["Close"].click()
        Wait.until(sync, \.exists, is: false)
    }

    deinit {
        // Nothing to release.
    }
}
