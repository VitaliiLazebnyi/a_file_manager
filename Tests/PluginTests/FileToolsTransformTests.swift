import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileToolsPlugin

/// Split, combine, encode and decode, through the plugin's commands and against the tools
/// that ship with macOS.
@MainActor @Suite struct FileToolsTransforms {
    let memory = MemoryFileSystem()
    let box: Sandbox
    let settings = MemorySettings()
    let bench: TestBench
    static let megabyteOfPattern = patternData(1_048_576)
    var megabyte: Data { Self.megabyteOfPattern }

    var ui: ScriptedInteraction { bench.interaction }
    var run: ToolRun { ToolRun(fileSystems: bench.kernel.fileSystems) }

    private let scratch = ScratchPasteboard()

    init() throws {
        box = try Sandbox()
        try box.folder("A")
        try box.folder("B")
        memory.addDirectory("/in")
        memory.addDirectory("/out")
        bench = TestBench(
            plugins: [FileToolsPlugin(pasteboard: scratch.pasteboard)],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
    }

    @discardableResult
    func write(_ path: String, _ data: Data) throws -> URL {
        try data.write(to: box.url(path))
        bench.left.reload()
        bench.left.moveCursor(toName: (path as NSString).lastPathComponent)
        return box.url(path)
    }

    func item(_ path: String) -> FileItem {
        guard let item = bench.kernel.fileSystems.item(at: box.url(path)) else {
            preconditionFailure("\(path) is missing")
        }
        return item
    }

    func data(_ path: String) -> Data? { try? Data(contentsOf: box.url(path)) }
    func byteCount(_ path: String) -> Int { data(path)?.count ?? -1 }

    /// Runs a command whose form is answered with `values` on top of its proposals.
    func perform(_ command: CommandID, cursor: String? = nil, _ values: [String: FormValues.Value] = [:]) {
        if let cursor {
            bench.left.reload()
            bench.left.moveCursor(toName: cursor)
        }
        ui.formAnswers = [.values(values)]
        #expect(bench.commands.perform(command))
    }

    // MARK: Registration

    @Test func commandsAndMenu() {
        let ids: [CommandID] = ["cm_Split", "cm_Combine", "cm_Encode", "cm_Decode", "cm_CRCcreate", "cm_CRCcheck"]
        #expect(bench.kernel.menus.menus.first?.items == ids)
        #expect(ids.allSatisfy { bench.commands[$0] != nil })
        #expect(bench.kernel.preferences.pages.map(\.title) == ["File Tools"])
        // Nothing under the cursor but `[..]`: the tools are not offered.
        #expect(!bench.commands.isEnabled(.splitFile) && !bench.commands.isEnabled(.createChecksums))
        _ = try? box.folder("A/dir")
        bench.left.reload()
        bench.left.moveCursor(toName: "dir")
        #expect(!bench.commands.isEnabled(.splitFile) && bench.commands.isEnabled(.createChecksums))
    }

    // MARK: Split

    @Test func splitSizes() {
        #expect(
            Splitter.size(from: "1000") == 1_000 && Splitter.size(from: " 2k ") == 2_048
                && Splitter.size(from: "1.5M") == 1_572_864
        )
        #expect(
            Splitter.size(from: "1G") == 1 << 30 && Splitter.size(from: "3 kb") == 3_072
                && Splitter.size(from: "1,024") == 1_024
        )
        #expect(Splitter.size(from: "360 k (5.25\")") == 362_496 && Splitter.size(from: "automatic") == 1_457_664)
        #expect(
            Splitter.size(from: "") == nil && Splitter.size(from: "0") == nil && Splitter.size(from: "-5") == nil
                && Splitter.size(from: "abc") == nil
        )
        #expect(Splitter.partName("random_1MB", 1) == "random_1MB.001" && Splitter.partName("x", 999) == "x.999")
        #expect(Splitter.presets.map(\.title).prefix(2) == ["Automatic", "1.44 MB (3.5\")"])
    }

    @Test func splitWritesPartsAndTheCrcFile() throws {
        let source = try write("A/random_1MB.bin", megabyte)
        // The fourth preset of the list is 360 k.
        perform(.splitFile, ["preset": .index(5)])
        #expect(namesOnDisk(box.url("B")) == ["random_1MB.001", "random_1MB.002", "random_1MB.003", "random_1MB.crc"])
        #expect(
            ["001", "002", "003", "crc"].map { byteCount("B/random_1MB." + $0) } == [362_496, 362_496, 323_584, 55]
        )
        let crc =
            UInt32(
                try systemTool("/usr/bin/cksum", ["-o", "3", source.path]).output.split(separator: " ").first ?? ""
            )
            ?? 0
        #expect(
            box.read("B/random_1MB.crc")
                == "filename=random_1MB.bin\r\nsize=1048576\r\ncrc32=\(String(format: "%08X", crc))\r\n"
        )
        #expect(
            (data("B/random_1MB.001") ?? Data()) + (data("B/random_1MB.002") ?? Data())
                + (data("B/random_1MB.003") ?? Data()) == megabyte
        )
        #expect(ui.log.suffix(2) == ["form: Split", "inform: Split"])
        #expect(bench.jobService.titles == ["Split:"] && bench.jobService.reports.last?.bytesDone == 1_048_576)
        #expect(bench.right.names == ["random_1MB.001", "random_1MB.002", "random_1MB.003", "random_1MB.crc"])
        #expect(ui.forms.last?[1].initialValue == .text(box.url("B").path))
    }

    @Test func splitByTypedSizeIntoTheSourceFolderAndOntoAnotherFileSystem() throws {
        try write("A/data.tar.gz", patternData(2_500))
        // An empty target is the source folder; the typed size is remembered.
        perform(.splitFile, ["target": .text(""), "size": .text("1k")])
        #expect(
            namesOnDisk(box.url("A")) == [
                "data.tar.001", "data.tar.002", "data.tar.003", "data.tar.crc", "data.tar.gz"
            ]
        )
        #expect(byteCount("A/data.tar.001") == 1_024 && byteCount("A/data.tar.003") == 452)
        #expect(settings.text(FileTools.Keys.splitSize, default: "") == "1k")
        // Any provider will do as a target, and a missing folder is created.
        perform(.splitFile, cursor: "data.tar.gz", ["target": .text("mem:/out/new"), "size": .text("2500")])
        #expect(
            memory.allPaths.filter { $0.hasPrefix("/out/new/") } == ["/out/new/data.tar.001", "/out/new/data.tar.crc"]
        )
    }

    @Test func splitRefusesBadSizesAndCleansUp() throws {
        try write("A/data.bin", patternData(5_000))
        perform(.splitFile, ["size": .text("lots")])
        #expect(ui.log.last == "inform: Split" && namesOnDisk(box.url("B")).isEmpty)
        perform(.splitFile, ["size": .text("5")])
        #expect(namesOnDisk(box.url("B")).isEmpty && bench.jobService.titles == ["Split:"])
        // A part that exists is asked about; Cancel (the default answer) leaves nothing new behind.
        try box.file("B/data.002", "old")
        perform(.splitFile, ["size": .text("2000")])
        #expect(namesOnDisk(box.url("B")) == ["data.002"] && box.read("B/data.002") == "old")
        ui.choiceAnswers = [1]
        perform(.splitFile, ["size": .text("2000")])
        #expect(
            namesOnDisk(box.url("B")) == ["data.001", "data.002", "data.003", "data.crc"]
                && byteCount("B/data.002") == 2_000
        )
        #expect(throws: ToolError.self) {
            try Splitter.split(item("A/data.bin"), into: box.url("B"), partSize: 0, run: run)
        }
    }

    @Test func splitOfAnEmptyFile() throws {
        try write("A/empty.txt", Data())
        perform(.splitFile, ["size": .text("100")])
        #expect(namesOnDisk(box.url("B")) == ["empty.001", "empty.crc"] && byteCount("B/empty.001") == 0)
        #expect(box.read("B/empty.crc") == "filename=empty.txt\r\nsize=0\r\ncrc32=00000000\r\n")
    }

    // MARK: Combine

    @Test func partSeries() {
        #expect(PartSeries.next(after: "file.001") == "file.002" && PartSeries.next(after: "file.099") == "file.100")
        #expect(
            PartSeries.next(after: "file.999") == nil && PartSeries.next(after: "notes.txt") == nil
                && PartSeries.next(after: "song.mp3") == nil
        )
        #expect(PartSeries.next(after: "name.00009.zip.part") == "name.00010.zip.part")
        #expect(
            PartSeries.next(after: "fileaa") == "fileab" && PartSeries.next(after: "fileaz") == "fileba"
                && PartSeries.next(after: "filezz") == nil
        )
        #expect(PartSeries.next(after: "file001.uue") == "file002.uue")
        #expect(
            PartSeries.combinedName(forPart: "movie.mkv.001") == "movie.mkv"
                && PartSeries.combinedName(forPart: "xaa") == "x"
        )
        #expect(
            PartSeries.combinedName(forPart: "name.00000.zip.part") == "name.zip.part"
                && PartSeries.combinedName(forPart: "001") == "001.combined"
        )
        #expect(
            SplitInfo(text: "filename=a b.bin\r\nsize=12\r\ncrc32=00FF00ff\r\n")
                == SplitInfo(name: "a b.bin", size: 12, crc: 0x00FF_00FF)
        )
        #expect(SplitInfo(text: "filename=a\nsize=x\ncrc32=1") == nil && SplitInfo(text: "") == nil)
    }

    @Test func combineFromTheFirstPartOrTheCrcFile() throws {
        try write("A/random_1MB.bin", megabyte)
        perform(.splitFile, ["target": .text(""), "size": .text("400k")])
        try FileManager.default.removeItem(at: box.url("A/random_1MB.bin"))
        perform(.combineFiles, cursor: "random_1MB.001")
        #expect(data("B/random_1MB.bin") == megabyte)
        #expect(ui.log.suffix(2) == ["form: Combine", "inform: Combine - 3"])
        if case .note = ui.forms.last?.first?.kind {
            #expect(
                ui.forms.last?.first?.label
                    == "Combine random_1MB.001 and all files with ascending names to the following directory:"
            )
        }
        perform(.combineFiles, cursor: "random_1MB.crc", ["target": .text("mem:/out")])
        #expect(memory.item(at: memory.url("/out/random_1MB.bin"))?.size == 1_048_576)
        #expect(bench.jobService.reports.last?.bytesDone == 1_048_576)
    }

    @Test func combineChecksTheCrc() throws {
        try write("A/data.bin", patternData(3_000))
        perform(.splitFile, ["target": .text(""), "size": .text("1000")])
        let plan = try Combiner.plan(for: item("A/data.001"), run: run)
        #expect(plan.parts.map(\.name) == ["data.001", "data.002", "data.003"] && plan.info?.size == 3_000)
        #expect(try Combiner.combine(plan.parts, info: plan.info, into: box.url("B"), run: run).verified == true)
        // A damaged part is found out.
        try Data(repeating: 7, count: 1_000).write(to: box.url("A/data.002"))
        let damaged = try Combiner.combine(plan.parts, info: plan.info, into: box.url("B"), run: run)
        #expect(damaged.verified == false && damaged.parts == 3)
        // So is a missing one: the row ends where a name is not there.
        try FileManager.default.removeItem(at: box.url("A/data.003"))
        let short = try Combiner.plan(for: item("A/data.001"), run: run)
        #expect(try Combiner.combine(short.parts, info: short.info, into: box.url("B"), run: run).verified == false)
        // A stored name with a path stays inside the target folder.
        let outside = try Combiner.combine(
            short.parts,
            info: SplitInfo(name: "../../evil.bin", size: 0, crc: 0),
            into: box.url("B"),
            run: run
        )
        #expect(outside.output == box.url("B/evil.bin"))
    }

    @Test func combineWithoutACrcFile() throws {
        for (index, text) in ["one ", "two ", "three"].enumerated() {
            try box.file("A/letter.txt.00\(index + 1)", text)
        }
        try box.file("A/xaa", "unix ")
        try box.file("A/xab", "split")
        perform(.combineFiles, cursor: "letter.txt.001")
        #expect(box.read("B/letter.txt") == "one two three" && ui.log.last == "inform: Combine - 3")
        perform(.combineFiles, cursor: "xaa")
        #expect(box.read("B/x") == "unix split" && ui.log.last == "inform: Combine - 2")
        // Into the folder of the parts themselves the whole must not replace a part.
        try box.file("A/001", "a")
        try FileManager.default.createDirectory(at: box.url("C"), withIntermediateDirectories: true)
        #expect(throws: ToolError.self) {
            try Combiner.combine(
                [item("A/letter.txt.001")],
                info: SplitInfo(name: "letter.txt.001", size: 4, crc: 0),
                into: box.url("A"),
                run: run
            )
        }
        #expect(box.read("A/letter.txt.001") == "one ")
        // A `.crc` file whose parts are gone.
        try box.file("A/lost.crc", "filename=lost.bin\r\nsize=1\r\ncrc32=00000000\r\n")
        perform(.combineFiles, cursor: "lost.crc")
        #expect(ui.log.last == "inform: Combine" && !box.exists("B/lost.bin"))
    }

    // MARK: Encode

    @Test func sixBitLines() {
        #expect(String(decoding: SixBitText.encode(Data("Cat".utf8), xx: false), as: UTF8.self) == "#0V%T\r\n")
        #expect(String(decoding: SixBitText.encode(Data("Cat".utf8), xx: true), as: UTF8.self) == "1Eq3o\r\n")
        #expect(SixBitText.decode(Array("#0V%T".utf8)[...], xx: false) == Array("Cat".utf8))
        #expect(SixBitText.decode(Array("1Eq3o".utf8)[...], xx: true) == Array("Cat".utf8))
        // A zero is a backquote in UUEncode, and a line whose spaces were cut off still reads.
        #expect(String(decoding: SixBitText.encode(Data([0, 0, 0]), xx: false), as: UTF8.self) == "#````\r\n")
        #expect(SixBitText.decode(Array("#    ".utf8)[...], xx: false) == [0, 0, 0])
        #expect(SixBitText.decode(Array("#0V%".utf8)[...], xx: false) == [0x43, 0x61, 0x40])
        #expect(
            SixBitText.decode(Array("#0V{T".utf8)[...], xx: false) == nil
                && SixBitText.decode(Array("1Eq#o".utf8)[...], xx: true) == nil
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

    @Test func uuencodeMatchesTheSystemTool() throws {
        let source = try write("A/decoded.txt", patternData(1_100))
        perform(.encodeFile, ["method": .index(1)])
        let ours = box.read("B/decoded.uue") ?? ""
        let reference = try systemTool("/usr/bin/uuencode", [source.path, "decoded.txt"]).output
        let sum =
            try systemTool("/usr/bin/sum", [source.path]).output.split(separator: " ").first.map(String.init) ?? ""
        #expect(ours == reference.replacingOccurrences(of: "\n", with: "\r\n") + "sum -r/size \(sum)/1100\r\n")
        #expect(ours.hasPrefix("begin 644 decoded.txt\r\nM") && ours.components(separatedBy: "\r\n")[1].count == 61)
        #expect(settings.index(FileTools.Keys.encodeMethod, default: 0) == 1)
        // The system's decoder reads it back.
        #expect(
            try systemTool("/usr/bin/uudecode", ["-o", box.url("B/back.txt").path, box.url("B/decoded.uue").path])
                .status == 0
        )
        #expect(data("B/back.txt") == patternData(1_100))
    }

    @Test func base64MatchesTheSystemTool() throws {
        let source = try write("A/decoded.txt", patternData(1_100))
        perform(.encodeFile)
        let ours = box.read("B/decoded.b64") ?? ""
        let parts = ours.components(separatedBy: "\r\n\r\n")
        #expect(
            parts.count == 2
                && parts[0] == "MIME-Version: 1.0\r\nContent-Type: application/octet-stream; name=\"decoded.txt\"\r\n"
                    + "Content-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"decoded.txt\""
        )
        let reference = try systemTool("/usr/bin/base64", ["-b", "76", "-i", source.path]).output
        #expect(parts.last == reference.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    @Test(arguments: EncodeMethod.allCases, [0, 1, 2, 3, 44, 45, 46, 56, 57, 58, 1_000, 150_000])
    func encodeAndDecodeRoundTrip(method: EncodeMethod, count: Int) throws {
        let original = patternData(count)
        try original.write(to: box.url("A/file.bin"))
        let encoded = try Encoder.encode(item("A/file.bin"), into: memory.url("/out"), method: method, run: run)
        #expect(encoded.map(\.lastPathComponent) == ["file." + method.fileExtension])
        let text = memory.contents("/out/file." + method.fileExtension) ?? ""
        #expect(
            text.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 }
                && !text.replacingOccurrences(of: "\r\n", with: "").contains("\n")
        )
        guard let first = memory.item(at: encoded[0]) else {
            return
        }
        #expect(try Decoder.decode(first, into: box.url("B"), run: run) == [box.url("B/file.bin")])
        #expect(data("B/file.bin") == original)
    }

    @Test(arguments: EncodeMethod.allCases)
    func encodeInSeveralParts(method: EncodeMethod) throws {
        let original = patternData(5_000)
        try write("A/big.dat", original)
        // 20 lines per file, or as many as fit into 10 lines' worth of bytes.
        let parts = try Encoder.encode(
            item("A/big.dat"),
            into: box.url("B"),
            method: method,
            linesPerFile: 20,
            bytesPerFile: Int64(10 * method.lineLength),
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

    // MARK: Decode

    @Test func decodesWhatTheSystemToolsWrite() throws {
        let original = patternData(70_001)
        let source = try write("A/sample.bin", original)
        func reference(_ tool: String, _ arguments: [String], as name: String) throws {
            try Data(try systemTool(tool, arguments).output.utf8).write(to: box.url("A/" + name))
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
            perform(.decodeFile, cursor: encoded)
            #expect(data("B/" + decoded) == original, "\(encoded)")
        }
        #expect(!ui.log.contains { $0.hasPrefix("inform") })
    }

    @Test func decodesMailsAndYEnc() throws {
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
        perform(.decodeFile)
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
        perform(.decodeFile)
        #expect(data("B/y enc.bin") == bytes)
    }

    @Test func decodeNamesTargetsAndClashes() throws {
        #expect(
            Decoder.safeName("a/b\\c.txt") == "c.txt" && Decoder.safeName("..") == nil && Decoder.safeName(nil) == nil
        )
        #expect(Decoder.safeName(" x:y\u{7}.txt ") == "x_y_.txt")
        #expect(
            Decoder.fallbackName(for: "photo.jpg.b64") == "photo.jpg"
                && Decoder.fallbackName(for: "noext") == "noext.decoded"
        )
        try write("A/plain.txt", Data("just some words, nothing encoded here\n".utf8))
        perform(.decodeFile)
        #expect(ui.log.last == "inform: Decode" && namesOnDisk(box.url("B")).isEmpty)

        try write("A/x.uue", Data("begin 644 out.txt\n#0V%T\n`\nend\n".utf8))
        // A target folder that does not exist is refused, not created.
        perform(.decodeFile, ["target": .text(box.url("missing").path)])
        #expect(ui.log.last == "inform: Decode" && !box.exists("missing"))
        perform(.decodeFile)
        #expect(box.read("B/out.txt") == "Cat")
        // The file is there now: Cancel leaves it, Skip too, Overwrite replaces it…
        try box.file("B/out.txt", "old")
        perform(.decodeFile)
        ui.choiceAnswers = [2]
        perform(.decodeFile)
        #expect(box.read("B/out.txt") == "old" && ui.log.contains { $0.hasPrefix("choose: Overwrite:") })
        ui.choiceAnswers = [0]
        perform(.decodeFile)
        #expect(box.read("B/out.txt") == "Cat")
        // …and "Auto-rename decoded files" writes next to it without asking.
        perform(.decodeFile, ["autoRename": .flag(true)])
        perform(.decodeFile, ["autoRename": .flag(true)])
        #expect(
            namesOnDisk(box.url("B")) == ["out(2).txt", "out(3).txt", "out.txt"] && box.read("B/out(3).txt") == "Cat"
        )
        // An unfinished file is still written with what there is.
        try write("A/cut.uue", Data("begin 644 cut.txt\n#0V%T\n".utf8))
        perform(.decodeFile)
        #expect(box.read("B/cut.txt") == "Cat")
    }

    @Test func cancellingLeavesNoHalfWrittenFiles() throws {
        try write("A/data.bin", megabyte)
        let stopped = ToolRun(fileSystems: bench.kernel.fileSystems)
        stopped.cancellation.cancel()
        #expect(throws: ToolError.cancelled) {
            try Splitter.split(item("A/data.bin"), into: box.url("B"), partSize: 100_000, run: stopped)
        }
        #expect(throws: ToolError.cancelled) {
            try Encoder.encode(item("A/data.bin"), into: box.url("B"), method: .uue, run: stopped)
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
            }
        )
        try Data(count: 3 << 20).write(to: box.url("A/large.bin"))
        #expect(throws: ToolError.cancelled) {
            try Splitter.split(item("A/large.bin"), into: box.url("B"), partSize: 300_000, run: half)
        }
        #expect(namesOnDisk(box.url("B")).isEmpty)
    }
}
