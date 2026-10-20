import XCTest

/// The commands of a drive on a real one: the disk image `run.sh` attaches (`AFM_VOLUME`, not
/// shown in Finder) is renamed and then ejected the way the user does it. `run.sh` detaches
/// and deletes the image afterwards should a test leave it attached.
@MainActor
internal final class LastVolumeTests: XCTestCase {
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

    /// Rename Volume… asks for the new name and the drive takes it; the panel follows it. Eject
    /// Volume then takes the panel off the drive, ejects it, and a notice says it can be removed.
    internal func testADriveIsRenamedAndEjected() throws {
        let volume = try XCTUnwrap(
            ProcessInfo.processInfo.environment["AFM_VOLUME"],
            "run.sh attaches a disk image and names it in AFM_VOLUME"
        )
        let session = try AppSession(leftFiles: [:])
        running = session
        try session.startLeft(in: URL(fileURLWithPath: volume, isDirectory: true))
        let window = try XCTUnwrap(session.launch(), "no main window")
        Wait.forElement(pathBar(of: window, endingWith: volume))
        let desktop = UIDesktop(session)

        desktop.menu("Commands", "More", "Rename Volume…")
        let question = session.app.dialogs.firstMatch
        Wait.forElement(question)
        let name = question.textFields.firstMatch
        Check.that(name.value as? String == URL(fileURLWithPath: volume).lastPathComponent, "it starts with the name")
        name.typeKey("a", modifierFlags: .command)
        name.typeText("AFM UI Renamed\n")
        Wait.until(question, \.exists, is: false)
        // The drive is mounted under its new name now: the panel climbs to where the drives are,
        // which lists it so.
        let list = window.tables.element(boundBy: 0)
        let drive = list.row(named: "[AFM UI Renamed]")
        Wait.forElement(drive)
        drive.doubleClick()
        let renamed = pathBar(of: window, endingWith: "/AFM UI Renamed")
        Wait.forElement(renamed)

        desktop.menu("Commands", "More", "Eject Volume")
        // The panel had been nowhere else: it goes to the home folder.
        Wait.until(renamed, \.exists, is: false)
        let notice = session.app.staticTexts
            .matching(NSPredicate(format: "value == %@", "“AFM UI Renamed” can now be removed safely."))
            .firstMatch
        Wait.forElement(notice)
        Wait.until(notice, \.exists, is: false)
    }

    deinit {
        // Nothing to release.
    }
}
