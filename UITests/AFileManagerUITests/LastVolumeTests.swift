import XCTest

/// The commands of a drive on a real one: the disk image `run.sh` attaches (`AFM_VOLUME`, not
/// shown in Finder) is renamed and then ejected the way the user does it. `run.sh` detaches
/// and deletes the image afterwards should a test leave it attached.
@MainActor
internal final class LastVolumeTests: XCTestCase {
    /// How many files the folder has that the panel goes back to: reading them takes a moment.
    private static let longFolderCount = 100_000

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

    /// The path bar of the left panel once it shows a folder whose path ends with `suffix`.
    private func pathBar(of window: XCUIElement, endingWith suffix: String) -> XCUIElement {
        window.staticTexts
            .matching(NSPredicate(format: "label == 'Current folder' AND value ENDSWITH %@", suffix + "/*.*"))
            .firstMatch
    }

    /// Changes the folder of the left panel with `cd` on the command line and waits until the
    /// path bar shows it.
    private func change(to folder: String, in window: XCUIElement) {
        let line = window.comboBoxes["Command line"]
        line.click()
        line.typeText("cd \"\(folder)\"\n")
        Wait.forElement(pathBar(of: window, endingWith: folder))
    }

    /// Rename Volume… asks for the new name and the drive takes it; the panel follows it.
    ///
    /// Eject Volume then takes the panel back to the folder it came from (a long one, which takes a
    /// moment to read), ejects the drive, and a notice says it can be removed. The user minimized
    /// the window meanwhile: the notice shows at the bottom of the screen on its own.
    ///
    /// The left panel shows the Brief view, which offers its long list to the accessibility
    /// interface as one element: XCUITest would take too long to go through a table of it.
    internal func testADriveIsRenamedAndEjected() throws {
        let volume = try XCTUnwrap(
            ProcessInfo.processInfo.environment["AFM_VOLUME"],
            "run.sh attaches a disk image and names it in AFM_VOLUME"
        )
        let session = try AppSession(leftFiles: [:])
        running = session
        try session.pin("left.view", to: ["mode": 1, "extraColumns": [], "columnWidths": [:]] as [String: Any])
        for index in 0..<Self.longFolderCount {
            FileManager.default.createFile(atPath: session.left.appendingPathComponent("f\(index)").path, contents: nil)
        }
        let window = try XCTUnwrap(session.launch(), "no main window")
        Wait.forElement(pathBar(of: window, endingWith: session.left.path))
        change(to: volume, in: window)
        let desktop = UIDesktop(session)

        desktop.menu("Commands", "More", "Rename Volume…")
        let question = session.app.dialogs.firstMatch
        Wait.forElement(question)
        let name = question.textFields.firstMatch
        Check.that(name.value as? String == URL(fileURLWithPath: volume).lastPathComponent, "it starts with the name")
        name.typeKey("a", modifierFlags: .command)
        name.typeText("AFM UI Renamed\n")
        Wait.until(question, \.exists, is: false)
        // The drive is mounted under its new name now: the panel climbs to where the drives are.
        Wait.forElement(pathBar(of: window, endingWith: "/Volumes"))

        // From the long folder onto the drive, so that the eject goes back there.
        change(to: session.left.path, in: window)
        let renamed = "/Volumes/AFM UI Renamed"
        change(to: renamed, in: window)
        desktop.menu("Commands", "More", "Eject Volume")
        session.app.typeKey("m", modifierFlags: .command)
        let notice = session.app.staticTexts
            .matching(NSPredicate(format: "value == %@", "“AFM UI Renamed” can now be removed safely."))
            .firstMatch
        Wait.forElement(notice)
        Wait.until(notice, \.exists, is: false)
        desktop.menu("Window", "A File Manager 0.1")
        Wait.until("the main window is back") { window.isHittable }
        Wait.forElement(pathBar(of: window, endingWith: session.left.path))
    }

    deinit {
        // Nothing to release.
    }
}
