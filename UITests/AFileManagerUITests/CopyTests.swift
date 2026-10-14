import Foundation
import XCTest

/// Copying with F5: the question where to, the copy itself, and both panels afterwards.
@MainActor
internal final class CopyTests: XCTestCase {
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

    /// F5 asks where to copy the file under the cursor (the other panel's folder), and OK
    /// copies it there; the right panel then lists it and the original stays.
    internal func testF5CopiesTheFileUnderTheCursorToTheOtherPanel() throws {
        let contents = String(repeating: "A File Manager copies this line.\n", count: 1_000)
        let session = try AppSession(leftFiles: ["report.txt": contents, "other.txt": "not copied"])
        running = session
        let window = try XCTUnwrap(session.launch(), "no main window")
        let left = window.tables.element(boundBy: 0)
        let right = window.tables.element(boundBy: 1)
        let report = left.row(named: "report")
        Wait.forElement(report)

        // [..], other, report: two rows down.
        window.typeKey(.downArrow, modifierFlags: [])
        window.typeKey(.downArrow, modifierFlags: [])
        Wait.until(report, \.isSelected, is: true)
        window.typeKey(.F5, modifierFlags: [])

        let dialog = session.app.dialogs.firstMatch
        Wait.forElement(dialog)
        Check.that(dialog.staticTexts["Copy \"report.txt\" to"].exists, "the question names the file")
        let target = try XCTUnwrap(dialog.textFields.firstMatch.value as? String)
        Check.that(target.hasPrefix(session.right.path), "copies to \(target), not to the right panel's folder")
        dialog.buttons["OK"].click()

        // The progress window, if it shows at all for a file this small, goes away with the
        // question, and the copy is complete.
        let copy = session.right.appendingPathComponent("report.txt")
        Wait.until("the copy is complete") { (try? String(contentsOf: copy, encoding: .utf8)) == contents }
        Wait.until(dialog, \.exists, is: false)
        Wait.forElement(right.row(named: "report"))
        let other = session.right.appendingPathComponent("other.txt")
        Check.that(!FileManager.default.fileExists(atPath: other.path), "only the file under the cursor is copied")
        let original = try String(contentsOf: session.left.appendingPathComponent("report.txt"), encoding: .utf8)
        Check.that(original == contents, "the original stays as it was")
    }
}
