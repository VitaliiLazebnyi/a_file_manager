import XCTest

/// The Lister's ways out to the system: the open and save panels, page setup and printing,
/// full screen and the window's zoom.
///
/// Every panel is cancelled: nothing is saved or printed.
@MainActor
internal final class UIViewerTests: XCTestCase {
    /// The program of the running test, once started.
    private var running: AppSession?

    /// `seconds` of silence as a WAV file: 8,000 samples a second, 16 bits, one channel.
    private static func silence(seconds: Int) -> Data {
        let samples = 8_000 * seconds
        var data = Data()
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put("RIFF")
        put(UInt32(36 + samples * 2))
        put("WAVEfmt ")
        put(UInt32(16))
        for value: UInt16 in [1, 1] { put(value) }
        for value: UInt32 in [8_000, 16_000] { put(value) }
        for value: UInt16 in [2, 16] { put(value) }
        put("data")
        put(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }

    /// A PDF of one page with a black box on it.
    private static func onePagePDF() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 40))
        context.endPDFPage()
        context.closePDF()
        return data as Data
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

    /// A file chosen in the open panel of Open… is what the Lister shows then.
    internal func testAFileChosenInTheOpenPanelIsShown() throws {
        let session = try AppSession(leftFiles: ["alpha.txt": "first\n", "beta.txt": "second\n"])
        running = session
        let lister = try openLister(session, downs: 1, named: "alpha")
        choose("Open…", of: "File", in: lister)
        UIDesktop(session).choose(session.left.appendingPathComponent("beta.txt").path, in: "the open panel")
        Wait.until("the Lister shows beta.txt") { lister.title.hasSuffix("beta.txt]") }
        lister.typeKey("q", modifierFlags: [])
        Wait.until(lister, \.exists, is: false)
    }

    /// A sound plays in the Lister's player as soon as it is shown; Space pauses it and plays it
    /// again, the arrows change the volume and move in it, M mutes it, E steps on, and moving
    /// past its end ends it.
    ///
    /// F2 loads it anew. (The Mac's sound is off while the tests run.).
    internal func testASoundPlaysInThePlayerAndItsKeysWork() throws {
        let session = try AppSession(leftFiles: [:])
        try Self.silence(seconds: 20).write(to: session.left.appendingPathComponent("quiet.wav"))
        running = session
        let lister = try openLister(session, downs: 1, named: "quiet")
        let playing = lister.checkBoxes["play/pause"]
        let volume = lister.sliders["volume"]
        Wait.forElement(playing)
        Wait.until("the sound plays") { playing.value as? Int == 1 }
        lister.typeKey(.space, modifierFlags: [])
        Wait.until("the sound is paused") { playing.value as? Int == 0 }
        lister.typeKey(.space, modifierFlags: [])
        Wait.until("the sound plays again") { playing.value as? Int == 1 }
        let loud = try XCTUnwrap(volume.value as? Double)
        lister.typeKey(.downArrow, modifierFlags: .shift)
        Wait.until("the volume is lower") { (volume.value as? Double).map { $0 < loud } == true }
        lister.typeKey(.upArrow, modifierFlags: .shift)
        Wait.until("the volume is back") { (volume.value as? Double).map { abs($0 - loud) < 0.001 } == true }
        lister.typeKey("m", modifierFlags: [])
        lister.typeKey("m", modifierFlags: [])
        lister.typeKey(.leftArrow, modifierFlags: .shift)
        lister.typeKey("e", modifierFlags: [])
        Wait.until("a step pauses the sound") { playing.value as? Int == 0 }
        lister.typeKey(.space, modifierFlags: [])
        lister.typeKey(.rightArrow, modifierFlags: .shift)
        lister.typeKey(.rightArrow, modifierFlags: .shift)
        Wait.until("the sound has played to its end") { playing.value as? Int == 0 }
        lister.typeKey(.F2, modifierFlags: [])
        Wait.until("the sound plays from the start") { playing.value as? Int == 1 }
        lister.typeKey("q", modifierFlags: [])
        Wait.until(lister, \.exists, is: false)
    }

    /// Page Setup… shows the system's page layout and Print… its print sheet; with text marked,
    /// the Lister asks first whether to print the marked text alone.
    ///
    /// Each is cancelled.
    ///
    /// The print panel and the page layout look for printers on the local network: the first
    /// time, macOS asks the user whether the program may (the owner has answered on this Mac).
    internal func testPageSetupAndPrintShowTheSystemsPanels() throws {
        let session = try AppSession(leftFiles: ["alpha.txt": "first line\nsecond line\n"])
        running = session
        let lister = try openLister(session, downs: 1, named: "alpha")
        let desktop = UIDesktop(session)

        choose("Page Setup…", of: "File", in: lister)
        desktop.cancelPanel("the page layout")
        choose("Print…", of: "File", in: lister)
        desktop.cancelPanel("the print sheet")

        choose("Select all", of: "Edit", in: lister)
        choose("Print…", of: "File", in: lister)
        let selection = session.app.dialogs.buttons["Selection"]
        Wait.forElement(selection)
        session.app.dialogs.buttons["Whole file"].click()
        Wait.until(selection, \.exists, is: false)
        desktop.cancelPanel("the print sheet of the whole file")

        lister.typeKey("q", modifierFlags: [])
        Wait.until(lister, \.exists, is: false)
    }

    /// A PDF prints through its own view: the system's print panel, cancelled.
    internal func testAPDFPrintsThroughThePrintPanel() throws {
        let session = try AppSession(leftFiles: [:])
        try Self.onePagePDF().write(to: session.left.appendingPathComponent("page.pdf"))
        running = session
        let lister = try openLister(session, downs: 1, named: "page")
        choose("Print…", of: "File", in: lister)
        UIDesktop(session).cancelPanel("the PDF's print panel")
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
