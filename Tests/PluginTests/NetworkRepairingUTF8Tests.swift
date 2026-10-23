import Testing

@testable import NetworkPlugin

/// How text a server sent as UTF-8 is read when it is not valid UTF-8.
@Suite
internal struct NetworkRepairingUTF8Tests {
    /// Valid UTF-8 is read as it is, a byte order mark included.
    @Test
    internal func validTextIsReadAsItIs() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("Grüße".utf8)
        #expect(String(repairingUTF8: bytes) == "\u{FEFF}Grüße")
        #expect(String(repairingUTF8: [UInt8]()).isEmpty)
    }

    /// Every broken sequence becomes one replacement character, the rest stays.
    @Test
    internal func brokenSequencesBecomeReplacementCharacters() {
        let bytes: [UInt8] = [0x41, 0xC3, 0x28, 0xF0, 0x9F, 0x41]
        #expect(String(repairingUTF8: bytes) == "A\u{FFFD}(\u{FFFD}A")
    }
}
