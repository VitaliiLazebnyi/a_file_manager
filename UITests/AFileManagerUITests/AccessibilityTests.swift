import XCTest

/// The accessibility audit of XCTest over the program: elements without a description, too
/// little contrast, controls too small to hit, text cut off, and the rest of its checks.
@MainActor
internal final class AccessibilityTests: XCTestCase {
    /// The program of the running test, once started.
    private var running: AppSession?

    /// Records every issue, not only the first.
    override internal func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
    }

    /// Quits the program and removes the test's folders.
    override internal func tearDown() async throws {
        if let running, !running.finish() {
            XCTFail("the program did not quit")
        }
        running = nil
        try await super.tearDown()
    }

    /// Every issue the audit finds in the main window, with files listed, fails the test.
    internal func testTheMainWindowPassesTheAccessibilityAudit() throws {
        let session = try AppSession(leftFiles: ["alpha.txt": "a", "beta.txt": "b"])
        running = session
        let window = try XCTUnwrap(session.launch(), "no main window")
        Wait.forElement(window.tables.element(boundBy: 0).row(named: "beta"))
        // The message names the element, which the audit's own message does not.
        try session.app.performAccessibilityAudit { issue in
            let element = issue.element.map { "\($0.elementType) \"\($0.identifier)\" \"\($0.label)\" \($0.frame)" }
            XCTFail("\(issue.compactDescription): \(element ?? "no element"). \(issue.detailedDescription)")
            return true
        }
    }
}
