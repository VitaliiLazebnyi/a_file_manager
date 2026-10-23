import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

/// Decode: what other programs write, mails, yEnc, names, clashes, and cancelling.
extension FileToolsTransforms {
    /// Decode reads what `uuencode` and `base64` write.
    @Test
    internal func decodesWhatTheSystemToolsWrite() throws {
        let original = FileToolsFixture.patternData(70_001)
        let source = try write("A/sample.bin", original)
        func reference(_ tool: String, _ arguments: [String], as name: String) throws {
            try Data(try FileToolsFixture.systemTool(tool, arguments, in: nil).output.utf8)
                .write(to: box.url("A/" + name))
        }
        try reference("/usr/bin/uuencode", [source.path, "from-uu.bin"], as: "ref.uue")
        try reference("/usr/bin/uuencode", ["-m", source.path, "from-uu-m.bin"], as: "ref-m.uue")
        // One line as long as the file, and no name inside: the file's own name is used.
        try reference("/usr/bin/base64", ["-i", source.path], as: "plain.b64")
        try reference("/usr/bin/base64", ["-b", "64", "-i", source.path], as: "wrapped.txt")
        for (encoded, decoded) in [
            ("ref.uue", "from-uu.bin"), ("ref-m.uue", "from-uu-m.bin"), ("plain.b64", "plain"),
            ("wrapped.txt", "wrapped")
        ] {
            perform(.decodeFile, cursor: encoded, [:])
            #expect(data("B/" + decoded) == original, "\(encoded)")
        }
        #expect(!interaction.log.contains { $0.hasPrefix("inform") })
    }

    /// Decode takes the attachments out of a mail, under names that stay in the folder, and reads yEnc.
    @Test
    internal func decodesMailsAndYEnc() throws {
        let mail = """
            From: someone
            Content-Type: multipart/mixed; boundary="xx"

            --xx
            Content-Type: text/plain

            SGVsbG8= is not for us.
            --xx
            Content-Type: application/octet-stream;
             name="fallback.bin"
            Content-Transfer-Encoding: BASE64
            Content-Disposition: attachment; filename="../dir/first:file.txt"

            SGVsbG8s
            IHdvcmxkIQ==
            --xx
            Content-Transfer-Encoding: base64
            Content-Type: image/png; name=second.png

            AAEC
            --xx--
            begin 600 third.txt
            #0V%T
            `
            end
            """
        try write("A/mail.eml", Data(mail.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        perform(.decodeFile, cursor: nil, [:])
        #expect(namesOnDisk(box.url("B")) == ["first_file.txt", "second.png", "third.txt"])
        #expect(
            box.read("B/first_file.txt") == "Hello, world!" && data("B/second.png") == Data([0, 1, 2])
                && box.read("B/third.txt") == "Cat"
        )

        // yEnc: every byte plus 42, with `=` in front of the few that need escaping.
        let bytes = Data((0..<600).map { UInt8($0 % 256) })
        var body: [UInt8] = []
        for (index, byte) in bytes.enumerated() {
            let encoded = byte &+ 42
            if [0, 10, 13, 61].contains(encoded) { body += [61, encoded &+ 64] } else { body.append(encoded) }
            if index % 128 == 127 { body += [13, 10] }
        }
        try write(
            "A/post.ync",
            Data("=ybegin line=128 size=600 name=y enc.bin\r\n".utf8) + Data(body)
                + Data("\r\n=yend size=600\r\n".utf8)
        )
        perform(.decodeFile, cursor: nil, [:])
        #expect(data("B/y enc.bin") == bytes)
    }

    /// Decode makes names safe, refuses a missing target, asks about a file in the way or renames, and
    /// writes an unfinished file as far as it goes.
    @Test
    internal func decodeNamesTargetsAndClashes() throws {
        #expect(
            Decoder.safeName("a/b\\c.txt", replacingColon: true) == "c.txt"
                && Decoder.safeName("..", replacingColon: true) == nil
                && Decoder.safeName(nil, replacingColon: true) == nil
        )
        #expect(Decoder.safeName(" x:y\u{7}.txt ", replacingColon: true) == "x_y_.txt")
        #expect(
            Decoder.fallbackName(for: "photo.jpg.b64") == "photo.jpg"
                && Decoder.fallbackName(for: "noext") == "noext.decoded"
        )
        try write("A/plain.txt", Data("just some words, nothing encoded here\n".utf8))
        perform(.decodeFile, cursor: nil, [:])
        #expect(interaction.log.last == "inform: Decode" && namesOnDisk(box.url("B")).isEmpty)

        try write("A/x.uue", Data("begin 644 out.txt\n#0V%T\n`\nend\n".utf8))
        // A target folder that does not exist is refused, not created.
        perform(.decodeFile, cursor: nil, ["target": .text(box.url("missing").path)])
        #expect(interaction.log.last == "inform: Decode" && !box.exists("missing"))
        perform(.decodeFile, cursor: nil, [:])
        #expect(box.read("B/out.txt") == "Cat")
        // The file is there now: Cancel leaves it, Skip too, Overwrite replaces it…
        try box.file("B/out.txt", "old")
        perform(.decodeFile, cursor: nil, [:])
        interaction.choiceAnswers = [2]
        perform(.decodeFile, cursor: nil, [:])
        #expect(box.read("B/out.txt") == "old" && interaction.log.contains { $0.hasPrefix("choose: Overwrite:") })
        interaction.choiceAnswers = [0]
        perform(.decodeFile, cursor: nil, [:])
        #expect(box.read("B/out.txt") == "Cat")
        // …and "Auto-rename decoded files" writes next to it without asking.
        perform(.decodeFile, cursor: nil, ["autoRename": .flag(true)])
        perform(.decodeFile, cursor: nil, ["autoRename": .flag(true)])
        #expect(
            namesOnDisk(box.url("B")) == ["out(2).txt", "out(3).txt", "out.txt"] && box.read("B/out(3).txt") == "Cat"
        )
        // An unfinished file is still written with what there is.
        try write("A/cut.uue", Data("begin 644 cut.txt\n#0V%T\n".utf8))
        perform(.decodeFile, cursor: nil, [:])
        #expect(box.read("B/cut.txt") == "Cat")
    }

    /// A cancelled tool, at the start or halfway, leaves nothing behind.
    @Test
    internal func cancellingLeavesNoHalfWrittenFiles() throws {
        try write("A/data.bin", megabyte)
        let stopped = ToolRun(fileSystems: bench.kernel.fileSystems)
        stopped.cancellation.cancel()
        #expect(throws: ToolError.cancelled) {
            try Splitter.split(item("A/data.bin"), into: box.url("B"), partSize: 100_000, run: stopped)
        }
        #expect(throws: ToolError.cancelled) {
            try Encoder.encode(
                item("A/data.bin"),
                into: box.url("B"),
                options: Encoder.Options(method: .uue),
                run: stopped
            )
        }
        #expect(throws: ToolError.cancelled) {
            try Combiner.combine([item("A/data.bin")], info: nil, into: box.url("B"), run: stopped)
        }
        #expect(namesOnDisk(box.url("B")).isEmpty)
        // Cancelled in the middle: the cancel flag is set when half of the bytes are through.
        let flag = CancellationFlag()
        let half = ToolRun(
            fileSystems: bench.kernel.fileSystems,
            cancellation: flag,
            report: { progress in
                if progress.bytesDone >= 500_000 { flag.cancel() }
            },
            askExisting: { _ in .overwrite }
        )
        try Data(count: 3 << 20).write(to: box.url("A/large.bin"))
        #expect(throws: ToolError.cancelled) {
            try Splitter.split(item("A/large.bin"), into: box.url("B"), partSize: 300_000, run: half)
        }
        #expect(namesOnDisk(box.url("B")).isEmpty)
    }
}
