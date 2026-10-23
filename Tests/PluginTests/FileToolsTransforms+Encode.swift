import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

/// Encode: the lines of the formats, compared with the programs of macOS, and the parts.
extension FileToolsTransforms {
    /// The lines of UUEncode and XXEncode, the names of encoded files, and the limits of one file.
    @Test
    internal func sixBitLines() {
        #expect(String(bytes: SixBitText.encode(Data("Cat".utf8), xxEncode: false), encoding: .ascii) == "#0V%T\r\n")
        #expect(String(bytes: SixBitText.encode(Data("Cat".utf8), xxEncode: true), encoding: .ascii) == "1Eq3o\r\n")
        #expect((try? SixBitText.decode(Array("#0V%T".utf8)[...], xxEncode: false)) == Array("Cat".utf8))
        #expect((try? SixBitText.decode(Array("1Eq3o".utf8)[...], xxEncode: true)) == Array("Cat".utf8))
        // A zero is a backquote in UUEncode, and a line whose spaces were cut off still reads.
        #expect(String(bytes: SixBitText.encode(Data([0, 0, 0]), xxEncode: false), encoding: .ascii) == "#````\r\n")
        #expect((try? SixBitText.decode(Array("#    ".utf8)[...], xxEncode: false)) == [0, 0, 0])
        #expect((try? SixBitText.decode(Array("#0V%".utf8)[...], xxEncode: false)) == [0x43, 0x61, 0x40])
        #expect(
            (try? SixBitText.decode(Array("#0V{T".utf8)[...], xxEncode: false)) == nil
                && (try? SixBitText.decode(Array("1Eq#o".utf8)[...], xxEncode: true)) == nil
        )
        #expect(Encoder.outputNames(for: "decoded.txt", method: .uue, parts: 1) == ["decoded.uue"])
        #expect(Encoder.outputNames(for: "a.b.txt", method: .mime, parts: 2) == ["a.b001.b64", "a.b002.b64"])
        #expect(
            Encoder.linesPerFile(lines: 0, bytes: 0, method: .mime) == 0
                && Encoder.linesPerFile(lines: 10, bytes: 0, method: .uue) == 10
        )
        #expect(
            Encoder.linesPerFile(lines: 0, bytes: 630, method: .uue) == 10
                && Encoder.linesPerFile(lines: 3, bytes: 7_800, method: .mime) == 3
        )
        #expect(Encoder.linesPerFile(lines: 0, bytes: 5, method: .mime) == 1)
    }

    /// What Encode writes as UUEncode is what `uuencode` writes, with `sum -r`, and `uudecode` reads it.
    @Test
    internal func uuencodeMatchesTheSystemTool() throws {
        let source = try write("A/decoded.txt", FileToolsFixture.patternData(1_100))
        perform(.encodeFile, cursor: nil, ["method": .index(1)])
        let ours = box.read("B/decoded.uue") ?? ""
        let reference = try FileToolsFixture.systemTool("/usr/bin/uuencode", [source.path, "decoded.txt"], in: nil)
            .output
        let printed = try FileToolsFixture.systemTool("/usr/bin/sum", [source.path], in: nil).output
        let sum = printed.split(separator: " ").first.map(String.init) ?? ""
        #expect(ours == reference.replacingOccurrences(of: "\n", with: "\r\n") + "sum -r/size \(sum)/1100\r\n")
        #expect(ours.hasPrefix("begin 644 decoded.txt\r\nM") && ours.components(separatedBy: "\r\n")[1].count == 61)
        #expect(settings.index(FileTools.Keys.encodeMethod, default: 0) == 1)
        // The system's decoder reads it back.
        #expect(
            try FileToolsFixture
                .systemTool(
                    "/usr/bin/uudecode",
                    ["-o", box.url("B/back.txt").path, box.url("B/decoded.uue").path],
                    in: nil
                )
                .status == 0
        )
        #expect(data("B/back.txt") == FileToolsFixture.patternData(1_100))
    }

    /// What Encode writes as MIME is the mail headers and what `base64` writes.
    @Test
    internal func base64MatchesTheSystemTool() throws {
        let source = try write("A/decoded.txt", FileToolsFixture.patternData(1_100))
        perform(.encodeFile, cursor: nil, [:])
        let ours = box.read("B/decoded.b64") ?? ""
        let parts = ours.components(separatedBy: "\r\n\r\n")
        #expect(
            parts.count == 2
                && parts[0] == "MIME-Version: 1.0\r\nContent-Type: application/octet-stream; name=\"decoded.txt\"\r\n"
                    + "Content-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"decoded.txt\""
        )
        let reference = try FileToolsFixture.systemTool("/usr/bin/base64", ["-b", "76", "-i", source.path], in: nil)
            .output
        #expect(parts.last == reference.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    /// Every format encodes and decodes files of lengths around its lines back to what they were.
    @Test(arguments: EncodeMethod.allCases, [0, 1, 2, 3, 44, 45, 46, 56, 57, 58, 1_000, 150_000])
    internal func encodeAndDecodeRoundTrip(method: EncodeMethod, count: Int) throws {
        let original = FileToolsFixture.patternData(count)
        try original.write(to: box.url("A/file.bin"))
        let encoded = try Encoder.encode(
            item("A/file.bin"),
            into: memory.url("/out"),
            options: Encoder.Options(method: method),
            run: run
        )
        #expect(encoded.map(\.lastPathComponent) == ["file." + method.fileExtension])
        let text = memory.contents("/out/file." + method.fileExtension) ?? ""
        #expect(
            text.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 }
                && !text.replacingOccurrences(of: "\r\n", with: "").contains("\n")
        )
        guard let first = memory.item(at: encoded[0]) else {
            return
        }
        #expect(try Decoder.decode(first, into: box.url("B"), autoRename: false, run: run) == [box.url("B/file.bin")])
        #expect(data("B/file.bin") == original)
    }

    /// A limit of lines or bytes splits the encoded text into numbered files, which Decode reads in a row.
    @Test(arguments: EncodeMethod.allCases)
    internal func encodeInSeveralParts(method: EncodeMethod) throws {
        let original = FileToolsFixture.patternData(5_000)
        try write("A/big.dat", original)
        // 20 lines per file, or as many as fit into 10 lines' worth of bytes.
        let parts = try Encoder.encode(
            item("A/big.dat"),
            into: box.url("B"),
            options: Encoder.Options(method: method, linesPerFile: 20, bytesPerFile: Int64(10 * method.lineLength)),
            run: run
        )
        let lines = (5_000 + method.bytesPerLine - 1) / method.bytesPerLine
        #expect(parts.count == (lines + 9) / 10 && parts.first?.lastPathComponent == "big001." + method.fileExtension)
        #expect(byteCount("B/big002." + method.fileExtension) == 10 * method.lineLength)
        // Decoding starts at the first part and finds the others by their counter.
        #expect(
            try Decoder.decode(
                item("B/big001." + method.fileExtension),
                into: box.url("A"),
                autoRename: true,
                run: run
            ) == [
                box.url("A/big(2).dat")
            ]
        )
        #expect(data("A/big(2).dat") == original)
        // The command asks for the same through its dialog.
        perform(
            .encodeFile,
            cursor: "big.dat",
            ["target": .text("mem:/out"), "method": .index(method.rawValue), "lines": .text("30")]
        )
        #expect(memory.allPaths.filter { $0.hasPrefix("/out/big") }.count == (lines + 29) / 30)
        #expect(settings.index(FileTools.Keys.encodeLines, default: 0) == 30)
    }
}
