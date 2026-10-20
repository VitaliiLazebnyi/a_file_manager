import XCTest

/// The program and the Mac's desktop: Quick Look, Finder, the applications that open a file and
/// the sharing picker. Whatever a test opens it closes again: the Quick Look panel, the Finder
/// window, TextEdit, the picker.
@MainActor
internal final class UIMacIntegrationTests: XCTestCase {
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

    /// Starts the program with alpha.txt and beta.txt and puts the cursor on alpha; returns the
    /// main window.
    private func start() throws -> (AppSession, XCUIElement) {
        let session = try AppSession(leftFiles: ["alpha.txt": "the first file\n", "beta.txt": "the second file\n"])
        running = session
        let window = try XCTUnwrap(session.launch(), "no main window")
        let alpha = window.tables.element(boundBy: 0).row(named: "alpha")
        Wait.forElement(alpha)
        window.typeKey(.downArrow, modifierFlags: [])
        Wait.until(alpha, \.isSelected, is: true)
        return (session, window)
    }

    /// Quick Look shows the file under the cursor in the system's panel, follows the cursor to
    /// the next file, and goes away when it is asked for again.
    internal func testQuickLookShowsTheFileUnderTheCursorAndFollowsIt() throws {
        let (session, window) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Files", "Quick Look")
        let panel = desktop.window(titled: "Quick Look")
        Wait.forElement(panel)
        Wait.forElement(panel.staticTexts["alpha.txt"])

        // The panel hands its keys to the file list.
        panel.typeKey(.downArrow, modifierFlags: [])
        Wait.until(window.tables.element(boundBy: 0).row(named: "beta"), \.isSelected, is: true)
        Wait.forElement(panel.staticTexts["beta.txt"])

        desktop.menu("Files", "Quick Look")
        Wait.until(panel, \.exists, is: false)
    }

    /// Reveal in Finder opens a Finder window on the file's folder; the test closes it.
    internal func testRevealInFinderShowsTheFolderInFinder() throws {
        let (session, _) = try start()
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        let folder = finder.windows[session.left.lastPathComponent]
        Check.that(!folder.exists, "no Finder window shows the test's folder before")
        UIDesktop(session).menu("Files", "More", "Reveal in Finder")
        Wait.forElement(folder)
        folder.buttons["_XCUI:CloseWindow"].click()
        Wait.until(folder, \.exists, is: false)
        session.app.activate()
    }

    /// Finder Info asks Finder, through AppleScript, for the Info window of the item under the
    /// cursor; the test closes it.
    ///
    /// The item is the Utilities folder in /Applications, outside the runner's container, whose
    /// items Finder does not show. The program needs the permission to control Finder (Privacy &
    /// Security › Automation); the first run asks.
    internal func testFinderInfoShowsFindersInfoWindowOfTheItem() throws {
        let session = try AppSession(leftFiles: [:])
        running = session
        try session.startLeft(in: URL(fileURLWithPath: "/Applications", isDirectory: true))
        let window = try XCTUnwrap(session.launch(), "no main window")
        let utilities = window.tables.element(boundBy: 0).row(named: "[Utilities]")
        Wait.forElement(utilities)
        utilities.click()
        Wait.until(utilities, \.isSelected, is: true)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        let info = finder.windows
            .matching(NSPredicate(format: "title == 'Utilities Info'"))
            .firstMatch
        Check.that(!info.exists, "no Info window of Utilities before")
        UIDesktop(session).menu("Files", "Finder Info")
        Wait.forElement(info)
        info.buttons["_XCUI:CloseWindow"].click()
        Wait.until(info, \.exists, is: false)
        session.app.activate()
    }

    /// Open with Default Application hands the file to TextEdit, which opens it.
    internal func testTheDefaultApplicationOpensTheFile() throws {
        let other = UIOtherApplication(UIOtherApplication.textEdit)
        textEdit = other
        let (session, _) = try start()
        UIDesktop(session).menu("Files", "Open with Default Application")
        other.waitUntilRunning()
        Wait.forElement(other.app.windows["alpha.txt"])
    }

    /// Open With… offers the applications for the file and Other…, which asks for one in the
    /// system's open panel (cancelled here: nothing opens); TextEdit, the first, opens it.
    internal func testOpenWithOpensTheChosenApplicationOrAsksForAnother() throws {
        let other = UIOtherApplication(UIOtherApplication.textEdit)
        textEdit = other
        let (session, _) = try start()
        let desktop = UIDesktop(session)

        // The second of the two items is the one that offers Other… (the first is the System
        // Tools' own, which `UISystemToolsTests` takes).
        desktop.menu("Files", item: "Open With…", number: 1)
        var choice = session.app.dialogs.firstMatch
        Wait.forElement(choice)
        choice.staticTexts["Other…"].click()
        choice.buttons["Open"].click()
        desktop.cancelPanel("the open panel for an application")
        Check.that(!other.isRunning, "nothing was opened")

        desktop.menu("Files", item: "Open With…", number: 1)
        choice = session.app.dialogs.firstMatch
        Wait.forElement(choice)
        Check.that(choice.staticTexts["TextEdit (default)"].exists, "TextEdit is offered first")
        choice.buttons["Open"].click()
        other.waitUntilRunning()
        Wait.forElement(other.app.windows["alpha.txt"])
    }

    /// An application chosen in the open panel of Other… opens the file.
    internal func testAnApplicationChosenInThePanelOpensTheFile() throws {
        let other = UIOtherApplication(UIOtherApplication.textEdit)
        textEdit = other
        let (session, _) = try start()
        let desktop = UIDesktop(session)
        desktop.menu("Files", item: "Open With…", number: 1)
        let choice = session.app.dialogs.firstMatch
        Wait.forElement(choice)
        choice.staticTexts["Other…"].click()
        choice.buttons["Open"].click()
        desktop.choose("/System/Applications/TextEdit.app", in: "the open panel for an application")
        other.waitUntilRunning()
        Wait.forElement(other.app.windows["alpha.txt"])
    }

    /// Share… shows the system's sharing picker, which Esc closes.
    internal func testShareShowsTheSharingPicker() throws {
        let (session, _) = try start()
        UIDesktop(session).menu("Files", "More", "Share…")
        Wait.until("the sharing picker is shown") { session.app.popovers.firstMatch.exists }
        session.app.typeKey(.escape, modifierFlags: [])
        Wait.until("the sharing picker has gone") { !session.app.popovers.firstMatch.exists }
    }

    deinit {
        // Nothing to release.
    }
}
