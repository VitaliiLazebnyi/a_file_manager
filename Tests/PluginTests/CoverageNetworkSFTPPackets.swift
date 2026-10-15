import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// The pieces of SFTP that are bytes: errors, attributes, packets, names.
@Suite
internal struct CoverageNetworkSFTPPackets {
    /// A status packet with `code` and, when given, a message.
    private func status(_ code: UInt32, message: String?) -> SFTPPacket {
        var encoder = SFTPEncoder()
        encoder.u32(code)
        if let message {
            encoder.string(message)
        }
        return SFTPPacket(kind: .status, body: encoder.data)
    }

    /// Every error status has a sentence; the server's own message comes first.
    @Test
    internal func everyErrorStatusHasASentence() {
        #expect(SFTPError(code: 4, message: "Disk full").errorDescription == "The server answered: Disk full")
        #expect(SFTPError(code: 2, message: "Failure").errorDescription?.contains("does not exist") == true)
        #expect(SFTPError(code: 3, message: "").errorDescription == "The server does not permit this.")
        #expect(SFTPError(code: 8, message: "").errorDescription?.contains("does not support") == true)
        #expect(SFTPError(code: 99, message: "").errorDescription == "The server reported an error (99).")
    }

    /// Attributes that say nothing make a plain, empty file.
    @Test
    internal func attributesThatSayNothingMakeAPlainFile() {
        let entry = SFTPAttributes().entry(named: "x")
        #expect(entry == RemoteEntry(name: "x", isDirectory: false))
        #expect(!entry.isSpecial)
    }

    /// Damaged packets, extended attributes and names that are not UTF-8 are read with care.
    @Test
    internal func packetsAreReadWithCare() throws {
        var encoder = SFTPEncoder()
        encoder.u32(0x8000_0004)
        encoder.u32(0o100644)
        encoder.u32(1)
        encoder.string("vendor@example.com")
        encoder.string("value")
        encoder.u8(7)
        encoder.bytes(Data([0x63, 0xE9]))
        var decoder = SFTPDecoder(encoder.data)
        #expect(try decoder.attributes().permissions == 0o100644)
        #expect(try decoder.u8() == 7)
        let name = try decoder.name()
        #expect(name.text == "c\u{E9}" && name.encoding == .isoLatin1)
        #expect(throws: NetworkError.self) { try decoder.u32() }
    }

    /// A packet that is no success status says what it is instead.
    @Test
    internal func aPacketThatIsNoSuccessSaysWhatItIs() {
        #expect(throws: NetworkError.self) { try SFTPPacket(kind: .closed, body: Data()).checkStatus() }
        #expect(throws: NetworkError.self) { try SFTPPacket(kind: .data, body: Data()).checkStatus() }
        #expect(throws: NetworkError.self) { try SFTPPacket(kind: .closed, body: Data()).expect(.handle) }
        #expect(throws: NetworkError.self) { try SFTPPacket(kind: .data, body: Data()).expect(.handle) }
        let bare = #expect(throws: SFTPError.self) { try status(3, message: nil).expect(.handle) }
        #expect(bare?.message.isEmpty == true)
        #expect(throws: Never.self) { try status(0, message: "OK").checkStatus() }
    }
}
