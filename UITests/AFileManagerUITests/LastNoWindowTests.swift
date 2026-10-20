import XCTest

/// What comes after the main window went off the screen: a file list of a large tree is read in
/// the background, and the user minimizes the window meanwhile; the print panel then comes on
/// its own, with no window to be a sheet of. It is cancelled, and the window brought back.
@MainActor
internal final class LastNoWindowTests: XCTestCase {
    /// The program of the running test, once started.
    private var running: AppSession?

    /// Makes `count` × `count` × 10 folders in `folder`: a tree that takes seconds to list.
    private static func makeTree(in folder: URL, count: Int) throws {
        for outer in 0..<count {
            for inner in 0..<count {
                for leaf in 0..<10 {
                    try FileManager.default.createDirectory(
                        at: folder.appendingPathComponent("o\(outer)/i\(inner)/l\(leaf)", isDirectory: true),
                        withIntermediateDirectories: true
                    )
                }
            }
        }
    }

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

    /// Print File List with Subfolders of the tree, the window minimized while the tree is
    /// read: the print panel shows by itself.
    internal func testTheFileListPrintsOnItsOwnWhenTheWindowWasMinimized() throws {
        let session = try AppSession(leftFiles: [:])
        running = session
        try Self.makeTree(in: session.left, count: 60)
        let window = try XCTUnwrap(session.launch(), "no main window")
        Wait.forElement(window.tables.element(boundBy: 0).row(named: "[o0]"))
        let desktop = UIDesktop(session)
        desktop.menu("Files", "More", "Print File List with Subfolders…")
        // The depth (all) and the files (all), then the form.
        for question in ["Depth of subfolders", "Files to include"] {
            let text = session.app.dialogs.staticTexts
                .matching(NSPredicate(format: "value BEGINSWITH %@", question))
                .firstMatch
            Wait.forElement(text)
            session.app.dialogs.buttons["OK"].firstMatch.click()
            Wait.until(text, \.exists, is: false)
        }
        let form = session.app.dialogs.containing(.staticText, identifier: "Print directory").firstMatch
        Wait.forElement(form)
        form.buttons["Print"].click()
        session.app.typeKey("m", modifierFlags: .command)
        // The panel is a window of its own, not a sheet of the minimized window.
        let panel = session.app.dialogs["Print"]
        Check.that(panel.waitForExistence(timeout: 4 * AppSession.patience), "the print panel shows")
        Check.that(!session.app.sheets.firstMatch.exists, "the print panel is no sheet")
        panel.buttons["Cancel"].click()
        Wait.until(panel, \.exists, is: false)
        desktop.menu("Window", "A File Manager 0.1")
        Wait.until("the main window is back") { window.isHittable }
    }

    deinit {
        // Nothing to release.
    }
}
