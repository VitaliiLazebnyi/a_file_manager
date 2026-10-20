import XCTest

/// A member of an archive handed to its application: Enter on it asks what to do, and Unpack
/// and Open gives it to TextEdit, which the test quits again.
@MainActor
internal final class UIArchiveTests: XCTestCase {
    /// The program of the running test, once started.
    private var running: AppSession?
    /// TextEdit, which the test makes the program start.
    private var textEdit: UIOtherApplication?

    /// A ZIP archive with one stored member, `name` holding `text`.
    private static func zip(_ name: String, _ text: String) -> Data {
        let body = Data(text.utf8)
        let path = Data(name.utf8)
        let crc = crc32(body)
        var archive = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { archive.append(contentsOf: $0) } }
        func put(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { archive.append(contentsOf: $0) } }
        // The member: version 2.0, stored, 1 January 1980.
        put(UInt32(0x0403_4b50))
        for value: UInt16 in [20, 0, 0, 0, 0x21] { put(value) }
        for value: UInt32 in [crc, UInt32(body.count), UInt32(body.count)] { put(value) }
        put(UInt16(path.count))
        put(UInt16(0))
        archive.append(path)
        archive.append(body)
        // The central directory, and its end.
        let start = UInt32(archive.count)
        put(UInt32(0x0201_4b50))
        for value: UInt16 in [20, 20, 0, 0, 0, 0x21] { put(value) }
        for value: UInt32 in [crc, UInt32(body.count), UInt32(body.count)] { put(value) }
        for value: UInt16 in [UInt16(path.count), 0, 0, 0, 0] { put(value) }
        for value: UInt32 in [0, 0] { put(value) }
        archive.append(path)
        let size = UInt32(archive.count) - start
        put(UInt32(0x0605_4b50))
        for value: UInt16 in [0, 0, 1, 1] { put(value) }
        put(size)
        put(start)
        put(UInt16(0))
        return archive
    }

    /// The CRC-32 of ZIP (the polynomial 0xEDB88320).
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    /// A test stops at its first failure: what follows depends on what failed.
    override internal func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    /// Quits TextEdit and the program, and removes the test's folders.
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

    /// Enter on the archive opens it; Enter on its member asks what to do with it; Unpack and
    /// Open hands the member to its application, TextEdit, which shows it.
    internal func testAMemberIsUnpackedAndOpenedInItsApplication() throws {
        let other = UIOtherApplication(UIOtherApplication.textEdit)
        textEdit = other
        let session = try AppSession(leftFiles: [:])
        try Self.zip("inside.txt", "a line inside the archive\n")
            .write(to: session.left.appendingPathComponent("packed.zip"))
        running = session
        let window = try XCTUnwrap(session.launch(), "no main window")
        let list = window.tables.element(boundBy: 0)
        let archive = list.row(named: "packed")
        Wait.forElement(archive)
        window.typeKey(.downArrow, modifierFlags: [])
        Wait.until(archive, \.isSelected, is: true)
        window.typeKey(.return, modifierFlags: [])
        let member = list.row(named: "inside")
        Wait.forElement(member)
        window.typeKey(.downArrow, modifierFlags: [])
        Wait.until(member, \.isSelected, is: true)
        window.typeKey(.return, modifierFlags: [])
        let question = session.app.dialogs.firstMatch
        Wait.forElement(question)
        question.buttons["Unpack and Open"].click()
        other.waitUntilRunning()
        Wait.forElement(other.app.windows["inside.txt"])
    }

    deinit {
        // Nothing to release.
    }
}
