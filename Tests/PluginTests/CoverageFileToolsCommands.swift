import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileToolsPlugin

/// The commands of the file tools beyond the other suites: dialogs that are cancelled or
/// answered out of range, targets that cannot be made, damaged parts and texts, and checksum
/// files in many folders.
@MainActor
@Suite
internal struct CoverageFileToolsCommands {
    /// The files: `/A` with a file and a folder, `/B` empty.
    private let memory = MemoryFileSystem()
    /// The memory files behind a layer that fails what a test names.
    private let files: CoverageSmallFiles
    /// The settings of the plugin.
    private let settings = MemorySettings()
    /// The kernel with the plugin, which looks for checksums on the general clipboard.
    private let bench: TestBench

    /// The kernel's commands.
    private var commands: CommandRegistry { bench.commands }
    /// The dialogs and messages, answered by script.
    private var dialogs: ScriptedInteraction { bench.interaction }

    /// The files and the kernel.
    internal init() {
        memory.addFile("/A/data.bin", "hello")
        memory.addDirectory("/A/docs")
        memory.addDirectory("/B")
        files = CoverageSmallFiles(memory)
        bench = TestBench(
            plugins: [FileToolsPlugin()],
            fileSystems: [files],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    /// Puts the cursor on `name` after the panel read its folder again.
    private func cursor(_ name: String) {
        bench.left.reload()
        bench.left.moveCursor(toName: name)
    }

    /// Cancelled dialogs start no job.
    @Test
    internal func cancelledDialogsStartNothing() {
        cursor("data.bin")
        for command in ["cm_Split", "cm_Combine", "cm_Encode", "cm_Decode", "cm_CRCcreate"] {
            commands.perform(CommandID(rawValue: command))
        }
        #expect(bench.jobService.titles.isEmpty && dialogs.forms.count == 5)
    }

    /// A target folder that cannot be made is said to be invalid.
    @Test
    internal func aTargetThatCannotBeMadeIsInvalid() {
        cursor("data.bin")
        files.fails = [.createDirectory]
        dialogs.formAnswers = [.values(["size": .text("2"), "target": .text("mem:/B/new")])]
        commands.perform("cm_Split")
        #expect(dialogs.log.last == "inform: Split" && !memory.exists("/B/new"))
    }

    /// Parts whose checksum does not match the `.crc` file are combined and said to be damaged.
    @Test
    internal func damagedPartsAreSaidToBeDamaged() {
        memory.addFile("/A/p.001", "ab")
        memory.addFile("/A/p.002", "c")
        memory.addFile("/A/p.crc", "filename=p\nsize=3\ncrc32=00000000\n")
        cursor("p.001")
        dialogs.formAnswers = [.values(["target": .text("mem:/B")])]
        commands.perform("cm_Combine")
        #expect(dialogs.log.last == "inform: Combine - 2" && memory.contents("/B/p") == "abc")
    }

    /// Encode shows the lines per file used last and takes a method out of range as MIME.
    @Test
    internal func encodeRemembersItsLinesAndFallsBackToMIME() {
        settings.set(5, forKey: FileTools.Keys.encodeLines)
        cursor("data.bin")
        dialogs.formAnswers = [.values(["method": .index(9), "target": .text("mem:/B")])]
        commands.perform("cm_Encode")
        #expect(dialogs.forms.first?.first { $0.key == "lines" }?.initialValue == .text("5"))
        #expect(settings.index(FileTools.Keys.encodeMethod, default: 7) == EncodeMethod.mime.rawValue)
        #expect(memory.allPaths.contains { $0.hasPrefix("/B/") })
    }

    /// More than eight problems of a decoded text are summed up.
    @Test
    internal func manyProblemsAreSummedUp() {
        let text = (0..<9).map { "begin-base64 644 f\($0)\nQ\n====\n" }.joined()
        memory.addFile("/A/many.b64", text)
        cursor("many.b64")
        dialogs.formAnswers = [.values(["target": .text("mem:/B")])]
        commands.perform("cm_Decode")
        #expect(dialogs.log.last == "inform: Decode")
        #expect(memory.allPaths.filter { $0.hasPrefix("/B/f") }.count == 9)
    }

    /// A stored method that does not exist is CRC32; a choice out of range keeps the method
    /// used last.
    @Test
    internal func checksumMethodsOutOfRange() {
        settings.set(99, forKey: FileTools.Keys.checksumMethod)
        cursor("data.bin")
        dialogs.formAnswers = [.values(["method": .index(99)])]
        commands.perform("cm_CRCcreate")
        #expect(memory.exists("/A/data.bin.sfv") || memory.exists("/A/data.sfv"))
        #expect(settings.index(FileTools.Keys.checksumMethod, default: 7) == ChecksumMethod.crc32.rawValue)
    }

    /// Checksum files in very many folders: only the folders the panels show are read again.
    @Test
    internal func checksumFilesInVeryManyFolders() {
        for index in 0...256 { memory.addFile("/A/docs/d\(index)/f.txt") }
        bench.right.show(memory.url("/A/docs/d7"))
        cursor("docs")
        dialogs.formAnswers = [.values(["separateFolders": .flag(true)])]
        commands.perform("cm_CRCcreate")
        #expect(memory.exists("/A/docs/d0/d0.sfv") && memory.exists("/A/docs/d256/d256.sfv"))
        #expect(bench.right.names.contains("d7.sfv"))
    }

    /// The result of Verify goes to the viewer where there is one.
    @Test
    internal func verifyShowsItsResultInTheViewer() {
        let viewer = CoverageFileToolsViewer()
        bench.kernel.services.register((any ViewerService).self, viewer)
        memory.addFile("/A/data.sfv", "data.bin 00000000\n")
        cursor("data.sfv")
        commands.perform("cm_CRCcheck")
        #expect(viewer.titles == ["CRC32: Errors: 1"] && bench.left.model.selection == ["data.bin"])
    }

    /// Several items at a root propose a checksum file named `checksums`.
    @Test
    internal func severalItemsAtARoot() {
        let proposal = FileTools.checksumProposal(count: 2, firstName: nil, in: memory.url("/"), method: .md5)
        #expect(proposal == memory.url("/checksums.md5"))
    }
}
