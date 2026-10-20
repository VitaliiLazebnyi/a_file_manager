import XCTest

/// A link in the Lister goes to the browser, Safari, which the test quits again.
///
/// The address is on this Mac and nothing answers there: the browser opens it and says it
/// cannot connect. No server runs for it, and nothing looks into the local network (which macOS
/// would ask the user about).
@MainActor
internal final class LastLinkTests: XCTestCase {
    /// The link: the discard port of this Mac, which refuses at once.
    private static let page = "http://127.0.0.1:9/afm-ui-page"

    /// The program of the running test, once started.
    private var running: AppSession?
    /// The browser, which the test makes the program start.
    private var browser: UIOtherApplication?

    /// A test stops at its first failure: what follows depends on what failed.
    override internal func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    /// Quits the browser and the program, and removes the test's folders.
    override internal func tearDown() async throws {
        if let browser, !browser.quit() {
            XCTFail("the browser did not quit")
        }
        if let running, !running.finish() {
            XCTFail("the program did not quit")
        }
        (running, browser) = (nil, nil)
        try await super.tearDown()
    }

    /// A right click on a web address in the text offers to open it in the default browser,
    /// which then opens a window for it.
    internal func testALinkInTheTextOpensInTheBrowser() throws {
        let other = UIOtherApplication("com.apple.Safari")
        browser = other
        // Every line is the address, so the click lands on it wherever the text begins.
        let session = try AppSession(leftFiles: ["link.txt": String(repeating: Self.page + "\n", count: 40)])
        running = session
        let window = try XCTUnwrap(session.launch(), "no main window")
        let file = window.tables.element(boundBy: 0).row(named: "link")
        Wait.forElement(file)
        window.typeKey(.downArrow, modifierFlags: [])
        Wait.until(file, \.isSelected, is: true)
        window.typeKey(.F3, modifierFlags: [])
        let lister = UIDesktop(session).window(titled: "Lister")
        Wait.forElement(lister)

        // The text starts below the Lister's menu strip, at its left.
        let strip = lister.menuButtons["File"].frame
        lister.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 40, dy: strip.maxY - lister.frame.minY + 40))
            .rightClick()
        let open = lister.menuItems["Open in the default browser"]
        Wait.forElement(open)
        open.click()
        other.waitUntilRunning()
        Wait.forElement(other.app.windows.firstMatch)
        lister.typeKey("q", modifierFlags: [])
        Wait.until(lister, \.exists, is: false)
    }

    deinit {
        // Nothing to release.
    }
}
