import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// The rare inputs of the decoders, each on its own: characters the code pages leave unassigned and
/// surrogates without their other half.
@Suite
internal struct DetermViewerDecoding {
    /// Four bytes of GB 18030 between the two ranges that are assigned, and past the last
    /// character, are one replacement character each; the characters at both ends are kept.
    @Test
    internal func unassignedFourByteCharactersOfGB18030AreReplaced() throws {
        let gb18030 = try #require(ViewerEncoding.codePage(54_936))
        let bytes: [UInt8] = [
            0x84, 0x31, 0xA4, 0x39,  // U+FFFF, the last of the plane
            0x85, 0x30, 0x81, 0x30,  // the first code after it, unassigned
            0x8F, 0x39, 0xFE, 0x39,  // the last code before U+10000, unassigned
            0x90, 0x30, 0x81, 0x30,  // U+10000
            0xE3, 0x32, 0x9A, 0x35,  // U+10FFFF, the last character there is
            0xE3, 0x32, 0x9A, 0x36,  // one past it
            0xFE, 0x39, 0xFE, 0x39  // the last code of all
        ]
        var text = DecodedText()
        #expect(gb18030.decode(bytes, final: true, into: &text) == bytes.count)
        #expect(text.units == [0xFFFF, 0xFFFD, 0xFFFD, 0xD800, 0xDC00, 0xDBFF, 0xDFFF, 0xFFFD, 0xFFFD])
        #expect(text.offsets == [0, 4, 8, 12, 12, 16, 16, 20, 24])
    }

    /// A high surrogate that is followed by something else than a low one is a replacement
    /// character, and what follows keeps its own meaning.
    @Test
    internal func aHighSurrogateWithoutItsLowOneIsReplaced() {
        var text = DecodedText()
        let little: [UInt8] = [0x3D, 0xD8, 0x41, 0x00, 0x3D, 0xD8, 0x3D, 0xD8, 0x00, 0xDE]
        #expect(ViewerEncoding.utf16LE.decode(little, final: true, into: &text) == little.count)
        #expect(text.units == [0xFFFD, 0x41, 0xFFFD, 0xD83D, 0xDE00])
        #expect(text.offsets == [0, 2, 4, 6, 6])
        let big: [UInt8] = [0xD8, 0x3D, 0x00, 0x42]
        #expect(ViewerEncoding.utf16BE.decode(big, final: true, into: &text) == big.count)
        #expect(text.units == [0xFFFD, 0x42])
    }

    /// A high surrogate at the very end is left for the next piece, and replaced when nothing follows.
    @Test
    internal func aHighSurrogateAtTheEndWaitsOrIsReplaced() {
        var text = DecodedText()
        let bytes: [UInt8] = [0x41, 0x00, 0x3D, 0xD8]
        #expect(ViewerEncoding.utf16LE.decode(bytes, final: false, into: &text) == 2 && text.units == [0x41])
        #expect(ViewerEncoding.utf16LE.decode(bytes, final: true, into: &text) == 4 && text.units == [0x41, 0xFFFD])
        // With a unit after it that has not arrived whole, it waits too.
        #expect(ViewerEncoding.utf16LE.decode(bytes + [0x00], final: false, into: &text) == 2)
    }
}
