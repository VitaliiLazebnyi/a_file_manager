import Foundation
import Testing

@testable import FileToolsPlugin

/// The decoder line by line, beyond the other suites: mail headers, Base64 with and without
/// marks, UUEncode and XXEncode lines that are damaged or of the other kind, the check lines
/// after them, and yEnc parts.
@Suite
internal struct CoverageFileToolsDecoding {
    /// A machine that hands its files to `sink`, fed `lines`.
    private func machine(_ lines: [String], into sink: CoverageFileToolsSink) throws -> DecodeMachine {
        let machine = DecodeMachine(sink: sink)
        for line in lines { try machine.feed(ArraySlice(Array(line.utf8))) }
        return machine
    }

    /// The UUEncode or XXEncode lines of `data`, without their line ends.
    private func sixBit(_ data: Data, xx asXX: Bool = false) -> [String] {
        let text = String(bytes: SixBitText.encode(data, xxEncode: asXX), encoding: .ascii) ?? ""
        return text.split(separator: "\r\n").map(String.init)
    }

    /// The CRC32 of bytes, as yEnc writes it.
    private func crc(_ bytes: [UInt8]) -> String {
        let hasher = CRC32Hasher()
        hasher.update(Data(bytes))
        return String(format: "%08x", hasher.checksum)
    }

    /// Mail headers are not yet a file: nothing more is needed while they are read.
    @Test
    internal func mailHeadersAreNoFileYet() throws {
        let sink = CoverageFileToolsSink()
        let headers = try machine(["Content-Type: text/plain"], into: sink)
        #expect(!headers.isInsideFile && !headers.needsMoreParts)
        try headers.feed([])
        try headers.finish()
        #expect(sink.files.isEmpty && headers.filesDecoded == 0)
    }

    /// A Base64 text with a begin mark and without its end is incomplete; one without a name is
    /// reported without one.
    @Test
    internal func base64WithoutItsEndMark() throws {
        let sink = CoverageFileToolsSink()
        let decoding = try machine(["begin-base64 644", "QUJD"], into: sink)
        #expect(decoding.needsMoreParts)
        try decoding.finish()
        #expect(sink.files.map(\.name) == [nil] && sink.files.first?.bytes == Array("ABC".utf8))
        #expect(decoding.problems == ["(no name): the end mark is missing: the text is incomplete"])
    }

    /// Plain Base64 in full lines of one length goes on; characters that are not Base64 are
    /// skipped and said; a line that starts a new file ends it; so does a boundary.
    @Test
    internal func plainBase64() throws {
        let sink = CoverageFileToolsSink()
        let lines = try machine(["QUJD", "REVG"], into: sink)
        #expect(lines.needsMoreParts)
        try lines.feed(ArraySlice(Array("R0*h J".utf8)))
        try lines.feed(ArraySlice(Array("begin 644 next".utf8)))
        try lines.feed(ArraySlice(Array("end".utf8)))
        try lines.finish()
        #expect(sink.files.map(\.name) == [nil, "next"] && sink.files[0].bytes == Array("ABCDEFGHI".utf8))
        #expect(lines.problems == ["(no name): 1 characters that are not Base64 were skipped"])
        let bounded = try machine(["QUJD", "--x!=="], into: CoverageFileToolsSink())
        #expect(bounded.filesDecoded == 1 && !bounded.isInsideFile)
    }

    /// Lines that start like UUEncode but are none are passed over; a file without a name
    /// whose check line does not match is reported without a name.
    @Test
    internal func uuencodeWithoutANameAndItsCheckLine() throws {
        let sink = CoverageFileToolsSink()
        let lines = ["begin 9x9 nothing", "begin 644"] + sixBit(Data("hello world".utf8)) + ["end", "sum -r/size 1/11"]
        let decoding = try machine(lines, into: sink)
        try decoding.finish()
        #expect(sink.files.map(\.name) == [nil] && sink.files[0].bytes == Array("hello world".utf8))
        #expect(decoding.problems == ["(no name): the checksum (sum -r) does not match: the data is damaged"])
    }

    /// Damage that nothing confirms is reported after the end line: lines passed over, short
    /// lines inside, and check lines that are no check lines.
    @Test
    internal func damageThatNothingConfirms() throws {
        let long = String(repeating: "x", count: 50)
        let encoded = sixBit(Data(long.utf8))
        let sink = CoverageFileToolsSink()
        let lines =
            [
                "begin 644 d", encoded[0], encoded[1], "", "~~~~", encoded[0], "end", "", "not a check line",
                "begin 644 e"
            ]
            + encoded + ["end", "sum -r/size x/y"]
        let decoding = try machine(lines, into: sink)
        try decoding.finish()
        #expect(sink.files.map(\.name) == ["d", "e"])
        #expect(decoding.problems.count == 1 && decoding.problems[0].hasPrefix("d: 2 lines could not be read"))
    }

    /// The kind of a six-bit text is told by its first line: XXEncode, a UUEncode line that
    /// lost its end, or neither.
    @Test
    internal func theKindIsToldByTheFirstLine() throws {
        let extended = CoverageFileToolsSink()
        try machine(["begin 644 x"] + sixBit(Data([0xFF, 0xFF, 0xFF]), xx: true) + ["end"], into: extended).finish()
        #expect(extended.files.first?.bytes == [0xFF, 0xFF, 0xFF])
        let cut = CoverageFileToolsSink()
        let line = sixBit(Data("ab".utf8))[0]
        try machine(["begin 644 u", String(line.dropLast()), "end"], into: cut).finish()
        #expect(cut.files.first?.bytes == Array("ab".utf8))
        let neither = CoverageFileToolsSink()
        try machine(["begin 644 n", "~~~~", "end"], into: neither).finish()
        #expect(neither.files.first?.bytes.isEmpty == true)
    }

    /// yEnc parts: a valid range, a damaged range, a range not given, a second header, and the
    /// checks at the end.
    @Test
    internal func yEncParts() throws {
        let bytes: [UInt8] = [55, 56, 57]
        let good = CoverageFileToolsSink()
        let part = try machine(
            [
                "=ybegin part=1 line=128 size=3 name=y.bin", "=ypart begin=1 end=3", "=ybegin part=1", "abc",
                "=yend size=3 part=1 pcrc32=\(crc(bytes))"
            ],
            into: good
        )
        #expect(good.files.first?.bytes == bytes && part.problems.isEmpty)
        let damaged = try machine(
            ["=ybegin part=1 line=128 name=d", "=ypart begin=0 end=x", "=ypart", "abc", "=yend"],
            into: CoverageFileToolsSink()
        )
        #expect(damaged.problems == ["d: the range of the part (=ypart begin= end=) is not valid: the text is damaged"])
        let short = try machine(
            ["=ybegin part=1 line=128 name=s", "=ypart begin=1 end=5", "abc", "=yend"],
            into: CoverageFileToolsSink()
        )
        #expect(short.problems == ["s: 3 bytes were decoded, but the part holds 5: the text is incomplete or damaged"])
        let whole = try machine(
            ["=ybegin line=128 size=5 name=w", "abc", "=yend pcrc32=00000000"],
            into: CoverageFileToolsSink()
        )
        #expect(
            whole.problems == [
                "w: 3 bytes were decoded, but =ybegin says 5: the text is incomplete or damaged",
                "w: the CRC32 does not match: the data is damaged"
            ]
        )
    }

    /// A mail header's file name is not taken from inside another word; names that are not
    /// UTF-8 are read as Latin-1.
    @Test
    internal func namesFromHeaders() throws {
        let sink = CoverageFileToolsSink()
        let headers = [
            "Content-Disposition: attachment; xfilename=bad; filename=good", "Content-Transfer-Encoding: base64", "",
            "QUJD"
        ]
        try machine(headers, into: sink).finish()
        let latin = CoverageFileToolsSink()
        let decoding = DecodeMachine(sink: latin)
        try decoding.feed(ArraySlice(Array("begin 644 caf".utf8) + [0xE9]))
        try decoding.finish()
        #expect(sink.files.map(\.name) == ["good"] && latin.files.map(\.name) == ["café"])
    }

    /// A name longer than a file system takes is cut at a code point.
    @Test
    internal func longNamesAreCut() {
        let name = Decoder.safeName(String(repeating: "é", count: 200), replacingColon: true)
        #expect(name?.utf8.count == 254 && name?.unicodeScalars.count == 127)
    }
}
