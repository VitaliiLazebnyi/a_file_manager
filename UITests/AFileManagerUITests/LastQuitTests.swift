import Foundation
import XCTest

/// Quitting while a plugin still writes. A member removed from an archive that lies in another
/// archive is written out only after a pause (copying a whole archive waits for one many times
/// as long as the copy, `OpenArchive.idleDelay`); then the inner archive goes back into the outer
/// one, compressed. A quit right after the removal has to do all that first: it shows a small
/// window that says so, and quits by itself once both archives are written.
@MainActor
internal final class LastQuitTests: XCTestCase {
    /// How large the noise in the inner archive is, in MB: compressing it again takes seconds.
    private static let noiseMegabytes = 1_536

    /// The program of the running test, once started.
    private var running: AppSession?

    /// Makes `outer`, a ZIP archive that holds `inner.zip` (stored), which holds `small.txt`
    /// and `noise.bin` (random bytes, stored); the files it makes on the way in `folder` go again.
    private static func makeArchives(in folder: URL, outer: URL) throws {
        let small = folder.appendingPathComponent("small.txt")
        let noise = folder.appendingPathComponent("noise.bin")
        let inner = folder.appendingPathComponent("inner.zip")
        defer {
            for file in [small, noise, inner] { try? FileManager.default.removeItem(at: file) }
        }
        try Data("a small member\n".utf8).write(to: small)
        try LastZip.writeNoise(megabytes: noiseMegabytes, to: noise)
        try LastZip.zip([small, noise], to: inner)
        try LastZip.zip([inner], to: outer)
    }

    /// A test stops at its first failure: what follows depends on what failed.
    override internal func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    /// Quits the program if it still runs, and removes the test's folders.
    override internal func tearDown() async throws {
        if let running, !running.finish() {
            XCTFail("the program did not quit")
        }
        running = nil
        try await super.tearDown()
    }

    /// Removing `small.txt` from `inner.zip` in `box.zip` and quitting at once: the window says
    /// the program finishes first, and the program quits by itself once the archives are
    /// written without the member.
    internal func testAQuitWaitsForAnArchiveToBeWrittenAndSaysSo() throws {
        let session = try AppSession(leftFiles: [:])
        running = session
        let archive = session.left.appendingPathComponent("box.zip")
        try Self.makeArchives(in: session.sandbox, outer: archive)
        let before = try XCTUnwrap(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let window = try XCTUnwrap(session.launch(), "no main window")
        let list = window.tables.element(boundBy: 0)

        // Into both archives, each time the one row after [..]; then onto small.txt, the last.
        for name in ["box", "inner"] {
            let row = list.row(named: name)
            Wait.forElement(row)
            window.typeKey(.downArrow, modifierFlags: [])
            Wait.until(row, \.isSelected, is: true)
            window.typeKey(.return, modifierFlags: [])
        }
        let small = list.row(named: "small")
        Wait.forElement(small)
        window.typeKey(.end, modifierFlags: [])
        Wait.until(small, \.isSelected, is: true)
        window.typeKey(.F8, modifierFlags: [])
        let question = session.app.dialogs.firstMatch
        Wait.forElement(question)
        // An archive has no Trash: the member goes for good, which is chosen, not Return's.
        question.buttons["Yes"].click()
        Wait.until(small, \.exists, is: false)

        session.app.typeKey("q", modifierFlags: .command)
        let finishing = session.app.staticTexts["Finishing before quitting…"]
        Wait.forElement(finishing)
        Check.that(session.app.buttons["Don’t Quit"].exists, "the window offers not to quit")
        Check.that(
            session.app.wait(for: .notRunning, timeout: 10 * AppSession.patience),
            "the program quits once the archives are written"
        )
        let after = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
        Check.that(after.map { $0 != before } == true, "the outer archive was written anew")
    }

    deinit {
        // Nothing to release.
    }
}
