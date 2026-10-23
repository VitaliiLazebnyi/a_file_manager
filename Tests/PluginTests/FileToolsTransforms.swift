import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileToolsPlugin

/// Split, combine, encode and decode, through the plugin's commands and against the tools
/// that ship with macOS.
@MainActor
@Suite
internal struct FileToolsTransforms {
    /// A megabyte of the test pattern, made once for all the tests.
    internal static let megabyteOfPattern = FileToolsFixture.patternData(1_048_576)

    /// A file system in memory, with the folders `/in` and `/out`.
    internal let memory = MemoryFileSystem()
    /// The folders `A` (the left panel) and `B` (the right) on disk.
    internal let box: Sandbox
    /// The settings of the bench.
    internal let settings = MemorySettings()
    /// The kernel with the plugin.
    internal let bench: TestBench
    /// A megabyte of the test pattern.
    internal var megabyte: Data { Self.megabyteOfPattern }

    /// The dialogs and messages of the bench, answered by script.
    internal var interaction: ScriptedInteraction { bench.interaction }
    /// A run of a tool without a job, on the bench's file systems.
    internal var run: ToolRun { ToolRun(fileSystems: bench.kernel.fileSystems) }

    /// A pasteboard of the test's own.
    private let scratch = ScratchPasteboard()

    /// A bench on the folders `A` and `B`.
    internal init() throws {
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

    /// Writes `data` to `path` of the box and puts the left panel's cursor on it.
    @discardableResult
    internal func write(_ path: String, _ data: Data) throws -> URL {
        try data.write(to: box.url(path))
        bench.left.reload()
        bench.left.moveCursor(toName: URL(fileURLWithPath: path).lastPathComponent)
        return box.url(path)
    }

    /// The file at `path` of the box, as its file system lists it.
    internal func item(_ path: String) -> FileItem {
        guard let item = bench.kernel.fileSystems.item(at: box.url(path)) else {
            preconditionFailure("\(path) is missing")
        }
        return item
    }

    /// The contents of the file at `path` of the box; nil when there is none.
    internal func data(_ path: String) -> Data? { try? Data(contentsOf: box.url(path)) }

    /// The size of the file at `path` of the box; -1 when there is none.
    internal func byteCount(_ path: String) -> Int { data(path)?.count ?? -1 }

    /// Runs a command, the cursor first on `cursor` when given, whose form is answered with `values` on top of its
    /// proposals.
    internal func perform(_ command: CommandID, cursor: String?, _ values: [String: FormValues.Value]) {
        if let cursor {
            bench.left.reload()
            bench.left.moveCursor(toName: cursor)
        }
        interaction.formAnswers = [.values(values)]
        #expect(bench.commands.perform(command))
    }

    // MARK: Registration

    /// The six commands are registered with their menu and preference page, and offered only on a file (the
    /// checksums also on a folder).
    @Test
    internal func commandsAndMenu() {
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

    /// Typed sizes are read in bytes, k, M and G, or as the caption of a preset; nothing else is a size.
    @Test
    internal func splitSizes() {
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

    /// Split writes the parts of a preset size and the `.crc` file with the CRC32 that `cksum` gives.
    @Test
    internal func splitWritesPartsAndTheCrcFile() throws {
        let source = try write("A/random_1MB.bin", megabyte)
        // The fourth preset of the list is 360 k.
        perform(.splitFile, cursor: nil, ["preset": .index(5)])
        #expect(namesOnDisk(box.url("B")) == ["random_1MB.001", "random_1MB.002", "random_1MB.003", "random_1MB.crc"])
        #expect(
            ["001", "002", "003", "crc"].map { byteCount("B/random_1MB." + $0) } == [362_496, 362_496, 323_584, 55]
        )
        let crc =
            UInt32(
                try FileToolsFixture.systemTool("/usr/bin/cksum", ["-o", "3", source.path], in: nil).output
                    .split(separator: " ").first ?? ""
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
        #expect(interaction.log.suffix(2) == ["form: Split", "inform: Split"])
        #expect(bench.jobService.titles == ["Split:"] && bench.jobService.reports.last?.bytesDone == 1_048_576)
        #expect(bench.right.names == ["random_1MB.001", "random_1MB.002", "random_1MB.003", "random_1MB.crc"])
        #expect(interaction.forms.last?[1].initialValue == .text(box.url("B").path))
    }

    /// An empty target splits into the source folder, a typed size is remembered, and another file
    /// system will do as a target.
    @Test
    internal func splitByTypedSizeIntoTheSourceFolderAndOntoAnotherFileSystem() throws {
        try write("A/data.tar.gz", FileToolsFixture.patternData(2_500))
        // An empty target is the source folder; the typed size is remembered.
        perform(.splitFile, cursor: nil, ["target": .text(""), "size": .text("1k")])
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

    /// Split refuses a bad size and too many parts, and a part in the way is asked about.
    @Test
    internal func splitRefusesBadSizesAndCleansUp() throws {
        try write("A/data.bin", FileToolsFixture.patternData(5_000))
        perform(.splitFile, cursor: nil, ["size": .text("lots")])
        #expect(interaction.log.last == "inform: Split" && namesOnDisk(box.url("B")).isEmpty)
        perform(.splitFile, cursor: nil, ["size": .text("5")])
        #expect(namesOnDisk(box.url("B")).isEmpty && bench.jobService.titles == ["Split:"])
        // A part that exists is asked about; Cancel (the default answer) leaves nothing new behind.
        try box.file("B/data.002", "old")
        perform(.splitFile, cursor: nil, ["size": .text("2000")])
        #expect(namesOnDisk(box.url("B")) == ["data.002"] && box.read("B/data.002") == "old")
        interaction.choiceAnswers = [1]
        perform(.splitFile, cursor: nil, ["size": .text("2000")])
        #expect(
            namesOnDisk(box.url("B")) == ["data.001", "data.002", "data.003", "data.crc"]
                && byteCount("B/data.002") == 2_000
        )
        #expect(throws: ToolError.self) {
            try Splitter.split(item("A/data.bin"), into: box.url("B"), partSize: 0, run: run)
        }
    }

    /// An empty file is split into one empty part.
    @Test
    internal func splitOfAnEmptyFile() throws {
        try write("A/empty.txt", Data())
        perform(.splitFile, cursor: nil, ["size": .text("100")])
        #expect(namesOnDisk(box.url("B")) == ["empty.001", "empty.crc"] && byteCount("B/empty.001") == 0)
        #expect(box.read("B/empty.crc") == "filename=empty.txt\r\nsize=0\r\ncrc32=00000000\r\n")
    }
}
