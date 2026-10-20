import XCTest

/// The Lister's ways out to the system: the open and save panels, full screen and the window's
/// zoom. Every panel is cancelled; nothing is saved.
@MainActor
internal final class UIViewerTests: XCTestCase {
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

    /// Starts the program with `files` in the left panel and opens the Lister (F3) on the one
    /// `downs` rows below `[..]`; returns its window.
    private func openLister(_ session: AppSession, downs: Int, named name: String) throws -> XCUIElement {
        let window = try XCTUnwrap(session.launch(), "no main window")
        Wait.forElement(window.tables.element(boundBy: 0).row(named: name))
        for _ in 0..<downs {
            window.typeKey(.downArrow, modifierFlags: [])
        }
        Wait.until(window.tables.element(boundBy: 0).row(named: name), \.isSelected, is: true)
        window.typeKey(.F3, modifierFlags: [])
        let lister = UIDesktop(session).window(titled: "Lister")
        Wait.forElement(lister)
        return lister
    }

    /// Chooses `item` of the Lister's menu `menu` (the strip at the top of its window).
    private func choose(_ item: String, of menu: String, in lister: XCUIElement) {
        let button = lister.menuButtons[menu]
        button.click()
        // An entry's title ends with its shortcuts, after a tab.
        let entry = button.menuItems
            .matching(NSPredicate(format: "title == %@ OR title BEGINSWITH %@", item, item + "\t"))
            .firstMatch
        Wait.forElement(entry)
        entry.click()
    }

    /// Open… and Save as… show the system's panels; each is cancelled, and the Lister still
    /// shows the file.
    ///
    /// Page Setup… and Print… are not tried: the system's print panel and page layout look for
    /// printers on the local network, which asks the user for that permission.
    internal func testTheFileMenuShowsTheSystemsPanels() throws {
        let session = try AppSession(leftFiles: ["alpha.txt": "first line\nsecond line\n"])
        running = session
        let lister = try openLister(session, downs: 1, named: "alpha")

        choose("Open…", of: "File", in: lister)
        UIDesktop(session).cancelPanel("the open panel")
        choose("Save as…", of: "File", in: lister)
        UIDesktop(session).cancelPanel("the save panel")

        Check.that(lister.title.hasSuffix("alpha.txt]"), "the Lister still shows alpha.txt, not \(lister.title)")
        lister.typeKey("q", modifierFlags: [])
        Wait.until(lister, \.exists, is: false)
    }

    /// Full screen puts the Lister's window over the whole screen and takes it back; Maximize
    /// zooms it and zooms it back.
    internal func testFullScreenAndMaximizeChangeTheWindowAndChangeItBack() throws {
        let session = try AppSession(leftFiles: ["alpha.txt": "a line\n"])
        running = session
        let lister = try openLister(session, downs: 1, named: "alpha")
        let before = lister.frame

        choose("Maximize", of: "Options", in: lister)
        Wait.until("the window is zoomed") { lister.frame != before }
        choose("Maximize", of: "Options", in: lister)
        Wait.until("the window has its size again") { lister.frame == before }

        choose("Full screen", of: "Options", in: lister)
        Wait.until("the window fills the screen") { lister.frame.width > before.width && lister.frame.minY == 0 }
        lister.typeKey("f", modifierFlags: [.command, .control])
        Wait.until("the window has left full screen") { lister.frame == before }

        lister.typeKey("q", modifierFlags: [])
        Wait.until(lister, \.exists, is: false)
    }

    deinit {
        // Nothing to release.
    }
}
