import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

/// Decode that must say what is missing, and names that must stay in the target folder.
extension Review2FileTools {
    /// Writes `bytes` to the file `name` and decodes it into `folder`.
    internal func decodeFile(_ name: String, _ bytes: [UInt8], into folder: String) throws -> Decoder.Outcome {
        try box.folder(folder)
        try Data(bytes).write(to: box.url(name))
        return try Decoder.decodeChecked(item(name), into: box.url(folder), autoRename: false, run: run())
    }

    /// URL-safe Base64 lines that start with dashes are data; in a mail such a line is a boundary.
    @Test
    internal func urlSafeBase64WithLeadingDashesIsNotCutOff() throws {
        // 0xFB 0xEF 0xBE is "----" in the URL-safe alphabet.
        let line = "----"
        let text = (0..<40).map { _ in line }.joined(separator: "\n") + "\n"
        let outcome = try decodeFile("dashes.b64", Array(text.utf8), into: "out")
        #expect(outcome.problems.isEmpty && outcome.files.count == 1)
        let expected = Data((0..<40).flatMap { _ in [UInt8]([0xFB, 0xEF, 0xBE]) })
        #expect(try Data(contentsOf: outcome.files[0]) == expected)
        // A boundary of a mail is still a boundary.
        let mail = "MIME-Version: 1.0\r\nContent-Transfer-Encoding: base64\r\n\r\nZm9vYmFy\r\n--boundary\r\n"
        let mailOutcome = try decodeFile("mail.eml", Array(mail.utf8), into: "out2")
        #expect(try Data(contentsOf: mailOutcome.files[0]) == Data("foobar".utf8))
    }

    /// Two unpadded Base64 files with numbers in their names are two files, not parts of one.
    @Test
    internal func unpaddedNumberedNeighboursAreNotGluedTogether() throws {
        try box.folder("out")
        try "Zm9vYmFy".write(to: box.url("photo1.b64"), atomically: true, encoding: .utf8)
        try "YmF6cXV4".write(to: box.url("photo2.b64"), atomically: true, encoding: .utf8)
        let outcome = try Decoder.decodeChecked(
            item("photo1.b64"),
            into: box.url("out"),
            autoRename: false,
            run: run()
        )
        #expect(try Data(contentsOf: outcome.files[0]) == Data("foobar".utf8))
        #expect(names("out") == ["photo1"])
    }

    /// The parts the encoder writes are decoded in a row into the whole.
    @Test
    internal func partsWrittenByTheEncoderStillJoin() throws {
        let content = Data((0..<5_000).map { index in UInt8(truncatingIfNeeded: index &* 7) })
        try content.write(to: box.url("data.bin"))
        try box.folder("enc")
        try box.folder("dec")
        let written = try Encoder.encode(
            item("data.bin"),
            into: box.url("enc"),
            options: Encoder.Options(method: .mime, linesPerFile: 20),
            run: run()
        )
        #expect(written.count > 1)
        let first = try #require(registry.item(at: written[0]))
        let outcome = try Decoder.decodeChecked(first, into: box.url("dec"), autoRename: false, run: run())
        #expect(outcome.problems.isEmpty)
        #expect(try Data(contentsOf: outcome.files[0]) == content)
    }

    /// Encodes `content` as UUEncode (with `xxEncode` as XXEncode) and returns the text.
    internal func encodeUU(_ content: Data, xxEncode: Bool) throws -> String {
        try content.write(to: box.url("src.bin"))
        try box.folder("enc")
        let written = try Encoder.encode(
            item("src.bin"),
            into: box.url("enc"),
            options: Encoder.Options(method: xxEncode ? .xxe : .uue),
            run: run()
        )
        return String(bytes: try Data(contentsOf: written[0]), encoding: .utf8) ?? ""
    }

    /// UUEncode without its end, with a line missing or damaged, is reported, and what there is is written.
    @Test
    internal func uuencodeThatIsIncompleteOrDamagedIsReported() throws {
        let content = Data((0..<450).map { index in UInt8(truncatingIfNeeded: index &* 13 &+ 5) })
        let good = try encodeUU(content, xxEncode: false)
        let correct = try decodeFile("good.uue", Array(good.utf8), into: "out")
        let correctData = try Data(contentsOf: correct.files[0])
        #expect(correct.problems.isEmpty && correctData == content)

        var lines = good.components(separatedBy: "\r\n")
        // Missing end (and everything after): the last part is missing.
        let cut = try #require(lines.firstIndex(of: "end"))
        let noEnd = lines[..<cut].joined(separator: "\r\n") + "\r\n"
        let incomplete = try decodeFile("noend.uue", Array(noEnd.utf8), into: "o2")
        #expect(incomplete.problems.count == 1 && incomplete.problems[0].contains("end"))
        #expect(incomplete.files.count == 1)

        // A line dropped from the middle: the size at the end does not agree.
        lines.remove(at: 4)
        let dropped = try decodeFile("dropped.uue", Array(lines.joined(separator: "\r\n").utf8), into: "o3")
        #expect(dropped.problems.count == 1 && dropped.problems[0].contains("405 bytes"))

        // A damaged line (a character that is not in the alphabet).
        var damaged = good.components(separatedBy: "\r\n")
        damaged[3] = String(damaged[3].dropLast(10)) + "~~~~~~~~~~"
        let bad = try decodeFile("bad.uue", Array(damaged.joined(separator: "\r\n").utf8), into: "o4")
        #expect(!bad.problems.isEmpty)
    }

    /// `content` as yEnc, whose `=yend` line gives `size` and `crc` (nil for the right ones).
    internal func yenc(_ content: [UInt8], size: Int?, crc: UInt32?) -> [UInt8] {
        var body: [UInt8] = []
        for byte in content {
            let encoded = byte &+ 42
            if encoded == 0 || encoded == 10 || encoded == 13 || encoded == 61 {
                body += [61, encoded &+ 64]
            } else {
                body.append(encoded)
            }
        }
        let hasher = CRC32Hasher()
        hasher.update(Data(content))
        let header = Array("=ybegin line=128 size=\(content.count) name=f.bin\r\n".utf8)
        let footer = Array(
            "\r\n=yend size=\(size ?? content.count) crc32=\(String(format: "%08x", crc ?? hasher.checksum))\r\n".utf8
        )
        return header + body + footer
    }

    /// The size and the CRC32 of yEnc are checked, and a cut text is reported.
    @Test
    internal func yencSizeAndCRCAreChecked() throws {
        let content = (0..<300).map { index in UInt8(truncatingIfNeeded: index &* 31) }
        let good = try decodeFile("good.yenc", yenc(content, size: nil, crc: nil), into: "out")
        let goodData = try Data(contentsOf: good.files[0])
        #expect(good.problems.isEmpty && goodData == Data(content))
        let wrongSize = try decodeFile("size.yenc", yenc(content, size: 999_999, crc: nil), into: "o2")
        #expect(wrongSize.problems.contains { problem in problem.contains("=yend says") })
        let wrongCRC = try decodeFile("crc.yenc", yenc(content, size: nil, crc: 0xDEAD_BEEF), into: "o3")
        #expect(wrongCRC.problems.contains { problem in problem.contains("CRC32") })
        let truncated = try decodeFile("cut.yenc", Array(yenc(content, size: nil, crc: nil).prefix(60)), into: "o4")
        #expect(truncated.problems.contains { problem in problem.contains("=yend") })
    }

    /// A name from encoded text or a `.crc` file never leads out of the target folder.
    @Test
    internal func namesFromEncodedTextStayInsideTheTargetFolder() throws {
        // A slash followed by a combining mark is one character to Swift and a slash to the disk.
        let name = "../\u{301}pwn.txt"
        #expect(Decoder.safeName(name, replacingColon: true)?.utf8.contains(0x2F) == false)
        #expect(Decoder.safeName("a/b\\c/..", replacingColon: true) == nil)
        #expect(Decoder.safeName("..\u{301}", replacingColon: true) == "..\u{301}")
        let uue = "begin 644 \(name)\n#<'=N\n`\nend\n"
        try box.folder("target/inner")
        try Data(uue.utf8).write(to: box.url("evil.uue"))
        let outcome = try Decoder.decodeChecked(
            item("evil.uue"),
            into: box.url("target/inner"),
            autoRename: false,
            run: run()
        )
        #expect(
            outcome.files.count == 1
                && outcome.files[0].deletingLastPathComponent().path == box.url("target/inner").path
        )
        #expect(names("target") == ["inner"])

        // The same for the name a .crc file gives to the combined file.
        #expect(Combiner.storedName("../\u{301}pwn.txt")?.utf8.contains(0x2F) == false)
        #expect(Combiner.storedName("..") == nil && Combiner.storedName("") == nil)
    }
}
