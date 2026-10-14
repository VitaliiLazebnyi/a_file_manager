import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing
import VirtualFoldersPlugin

@testable import ClipboardPlugin
@testable import FileOperationsPlugin
@testable import FilePropertiesPlugin

// Regression tests of review round 2 for the commands of the file-operation plugins, the
// clipboard and the file properties (documentation/review-2/findings/fileops.md).

@MainActor @Suite struct Review2FileopsCommands {
    let box: Sandbox
    private let scratch = ScratchPasteboard()
    var pasteboard: NSPasteboard { scratch.pasteboard }
    let virtual = VirtualFoldersPlugin()
    let bench: TestBench

    var ui: ScriptedInteraction { bench.ui }
    var commands: CommandRegistry { bench.commands }

    init() throws {
        box = try Sandbox()
        try box.file("d/a.txt", "precious")
        try box.file("d/b.txt", "second")
        try box.file("d/sub/c.txt", "deep")
        try box.folder("t")
        bench = TestBench(
            plugins: [
                virtual, FileOperationsPlugin(), ClipboardPlugin(pasteboard: scratch.pasteboard), SelectionPlugin()
            ],
            fileSystems: [LocalFileSystem()],
            left: box.url("d"),
            right: box.url("t")
        )
    }

    private func branch(of path: String) throws -> URL {
        try #require(virtual.fileSystem).branch(of: box.url(path))
    }

    // F001, F018: what Paste after Cut does in a branch view.
    @Test func movingFilesIntoTheBranchViewTheyAreShownInChangesNothing() throws {
        let transfers = try #require(bench.kernel.services.find((any FileTransferService).self))
        var ended = false
        transfers.transfer(
            .move,
            [box.url("d/a.txt"), box.url("d/b.txt")],
            into: try branch(of: "d"),
            renamingSelfCopies: false
        ) { _ in ended = true }
        #expect(ended && box.read("d/a.txt") == "precious" && box.read("d/b.txt") == "second")
        #expect(namesOnDisk(box.url("d")) == ["a.txt", "b.txt", "sub"])
        // Nothing to do is nothing to tell.
        #expect(!ui.log.contains { $0.hasPrefix("inform") })
        // A file of a subfolder is moved up into the folder of the branch, by a rename.
        transfers.transfer(.move, [box.url("d/sub/c.txt")], into: try branch(of: "d"), renamingSelfCopies: false) { _ in
        }
        #expect(box.read("d/c.txt") == "deep" && !box.exists("d/sub/c.txt"))
    }

    @Test func pastingACopyIntoABranchViewGivesItANewNameInTheRealFolder() throws {
        let transfers = try #require(bench.kernel.services.find((any FileTransferService).self))
        transfers.transfer(.copy, [box.url("d/a.txt")], into: try branch(of: "d"), renamingSelfCopies: true) { _ in }
        #expect(
            namesOnDisk(box.url("d")) == ["a (2).txt", "a.txt", "b.txt", "sub"] && box.read("d/a.txt") == "precious"
        )
    }

    @Test func nothingCanBePastedIntoAListOfFiles() throws {
        let transfers = try #require(bench.kernel.services.find((any FileTransferService).self))
        let list = try #require(virtual.fileSystem)
            .register(
                files: [box.url("d/a.txt")],
                title: "Found",
                origin: box.url("d")
            )
        transfers.transfer(.copy, [box.url("d/b.txt")], into: list, renamingSelfCopies: false) { _ in }
        #expect(ui.log.contains { $0.hasPrefix("inform") && $0.contains("list of files") })
        #expect(namesOnDisk(box.root) == ["d", "t"] && namesOnDisk(box.url("t")).isEmpty)
    }

    // F026
    @Test func copyingTowardsABranchViewGoesIntoTheRealFolder() throws {
        bench.right.show(try branch(of: "t"))
        bench.left.moveCursor(toName: "a.txt")
        ui.promptAnswers = [.accept]
        commands.perform(.copy)
        // The proposal names the real folder; no folder called "t (branch)" appears.
        #expect(ui.log.contains("prompt: Copy \"a.txt\" to [\(box.url("t").path)/a.txt]"))
        #expect(box.read("t/a.txt") == "precious" && namesOnDisk(box.root) == ["d", "t"])
    }

    @Test func aListOfFilesIsNotOfferedAsATarget() throws {
        bench.right.show(
            try #require(virtual.fileSystem)
                .register(
                    files: [box.url("d/a.txt")],
                    title: "Found",
                    origin: box.url("d")
                )
        )
        bench.left.moveCursor(toName: "b.txt")
        ui.promptAnswers = [.accept]
        commands.perform(.copy)
        // The proposal is the name alone, never "Found (list 7)/b.txt", which would read as a folder to make.
        #expect(
            ui.log.contains("prompt: Copy \"b.txt\" to [b.txt]")
                && ui.log.contains("inform: You cannot copy a file to itself!")
        )
        #expect(namesOnDisk(box.root) == ["d", "t"] && namesOnDisk(box.url("d")) == ["a.txt", "b.txt", "sub"])
    }

    // F001: a rename typed in a branch view.
    @Test func renamingInABranchViewWithF6IsARename() throws {
        bench.left.show(try branch(of: "d"))
        bench.left.moveCursor(toName: "a.txt")
        var info = stat()
        #expect(lstat(box.url("d/a.txt").path, &info) == 0)
        let before = info.st_ino
        ui.promptAnswers = [.text("A.TXT")]
        commands.perform(.renameMove)
        #expect(namesOnDisk(box.url("d")) == ["A.TXT", "b.txt", "sub"] && box.read("d/A.TXT") == "precious")
        #expect(lstat(box.url("d/A.TXT").path, &info) == 0 && info.st_ino == before)
    }

    // F056, F006: several items renamed with one mask.
    @Test func aRenameOfSeveralItemsToOneNameKeepsThemAllAndAsksOnce() {
        bench.left.moveCursor(toName: "a.txt")
        commands.perform(.selectAll)
        bench.left.model.setSelected(false, names: ["sub"])
        ui.formAnswers = [.values(["mask": .text("same.txt")])]
        // "Overwrite all" to the one question; it must not cost the first file its contents.
        ui.choiceAnswers = [1]
        commands.perform(.renameOnly)
        #expect(namesOnDisk(box.url("d")) == ["same (2).txt", "same.txt", "sub"])
        #expect(Set([box.read("d/same.txt"), box.read("d/same (2).txt")]) == ["precious", "second"])
        #expect(ui.log.filter { $0.hasPrefix("choose: Overwrite") }.count == 1)
    }

    @Test func aRenameOfSeveralItemsInABranchViewLeavesEachInItsFolder() throws {
        bench.left.show(try branch(of: "d"))
        bench.left.moveCursor(toName: "a.txt")
        commands.perform(.selectAll)
        ui.formAnswers = [.values(["mask": .text("*.bak")])]
        commands.perform(.renameOnly)
        #expect(namesOnDisk(box.url("d")) == ["a.bak", "b.bak", "sub"] && namesOnDisk(box.url("d/sub")) == ["c.bak"])
    }

    // F002, F004, F011, F071
    @Test func aLargeSelectionIsRememberedAndOnlyWrittenOutWhenAskedFor() throws {
        let count = ClipboardPlugin.eagerLimit + 5
        for index in 0..<count { try box.file("many/f\(index).txt", "\(index)") }
        bench.left.show(box.url("many"))
        bench.left.moveCursor(toName: "f0.txt")
        commands.perform(.selectAll)
        // "For This Program": one item on the pasteboard, the paths as a text made on demand.
        ui.choiceAnswers = [0]
        commands.perform(.copyToClipboard)
        #expect(ui.log.contains { $0.hasPrefix("choose: Copy \(count) files") })
        #expect(
            pasteboard.pasteboardItems?.count == 1
                && pasteboard.canReadObject(forClasses: [NSURL.self], options: nil) == false
        )
        #expect(pasteboard.string(forType: .string)?.split(separator: "\n").count == count)
        // Paste here takes the files from memory.
        #expect(commands.isEnabled(.pasteFromClipboard))
        bench.right.focus()
        commands.perform(.pasteFromClipboard)
        #expect(namesOnDisk(box.url("t")).count == count && box.read("t/f\(count - 1).txt") == "\(count - 1)")
        // "Also for Other Programs": every file is on the pasteboard.
        bench.left.focus()
        ui.choiceAnswers = [1]
        commands.perform(.copyToClipboard)
        #expect((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.count == count)
        // Cancel leaves the clipboard as it is.
        pasteboard.clearContents()
        pasteboard.setString("kept", forType: .string)
        ui.choiceAnswers = [2]
        commands.perform(.cutToClipboard)
        #expect(pasteboard.string(forType: .string) == "kept")
        // A small selection is written the usual way and nobody is asked.
        commands.perform(.unselectAll)
        bench.left.moveCursor(toName: "f1.txt")
        let questions = ui.log.count
        commands.perform(.copyToClipboard)
        #expect(ui.log.count == questions)
        #expect((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.lastPathComponent) == ["f1.txt"])
    }

    @Test func filesAnotherProgramOffersAsOneListAreReadInOnePiece() {
        bench.right.focus()
        // Files written by somebody else: the system offers them as one list as well.
        pasteboard.clearContents()
        pasteboard.writeObjects([box.url("d/a.txt") as NSURL, box.url("d/b.txt") as NSURL])
        #expect((pasteboard.propertyList(forType: ClipboardPlugin.fileNamesType) as? [String])?.count == 2)
        #expect(commands.isEnabled(.pasteFromClipboard))
        commands.perform(.pasteFromClipboard)
        #expect(namesOnDisk(box.url("t")) == ["a.txt", "b.txt"])
        // The answer is remembered per state of the pasteboard, and follows it.
        pasteboard.clearContents()
        #expect(!commands.isEnabled(.pasteFromClipboard))
    }

    // F040
    @Test func aTextIsPastedAsAFileWithoutLeavingADraft() {
        pasteboard.clearContents()
        pasteboard.setString("some text", forType: .string)
        bench.right.focus()
        commands.perform(.pasteFromClipboard)
        #expect(namesOnDisk(box.url("t")) == ["Clipboard.txt"] && box.read("t/Clipboard.txt") == "some text")
    }

    // F055
    @Test func namesThatCouldMisleadAreWrittenOutInQuestions() {
        #expect(DisplayName.escaped("plain name.txt") == "plain name.txt")
        #expect(DisplayName.escaped("a\nb\u{202E}txt.exe\u{200B}") == "a<U+000A>b<U+202E>txt.exe<U+200B>")
        let item = FileItem(url: box.url("d/x\ny"), name: "x\ny")
        #expect(OperationText.deleteQuestion([item], toTrash: false).contains("x<U+000A>y"))
        #expect(OperationText.heading("Copy", [item]) == "Copy \"x<U+000A>y\" to")
        #expect(PropertyText.shown("a\u{202E}b") == "a<U+202E>b")
    }
}

@Suite struct Review2FileopsNames {
    // F014, F015, F016: reproducers of the fuzzer, as typed text.
    @Test func rangesNearTheEndsOfIntDoNotCrash() throws {
        var context = NameTemplate.Context()
        context.cursorName = "report.txt"
        #expect(
            try NameTemplate.names(from: "<[N1,-9223372036854775808]", context: context) == [
                "[N1,-9223372036854775808]"
            ]
        )
        // A number of nineteen digits is no position; the bracket stays as typed.
        #expect(
            try NameTemplate.names(from: "<x[N9223372036854775807--9223372036854775807]", context: context)
                == ["x[N9223372036854775807--9223372036854775807]"]
        )
        #expect(
            try NameTemplate.names(from: "<x[N1,9223372036854775807]", context: context) == [
                "x[N1,9223372036854775807]"
            ]
        )
        // Large numbers that are positions are cut to the length of the name.
        #expect(try NameTemplate.names(from: "<x[N999999999999999999--999999999999999999]", context: context) == ["x"])
        #expect(try NameTemplate.names(from: "<x[N1,999999999999999999]", context: context) == ["xreport"])
        #expect(try NameTemplate.names(from: "<x[N-999999999999999999-]", context: context) == ["xreport"])
        #expect(
            try NameTemplate.names(from: "<x[N99999999999999999999]", context: context) == ["x[N99999999999999999999]"]
        )
        #expect(try NameTemplate.names(from: "<x[C:-9223372036854775808]", context: context) == ["x"])
        #expect(try NameTemplate.names(from: "<1-2>x[C:-9223372036854775808]", context: context) == ["x1", "x2"])
        // The ranges that are meant still work.
        #expect(
            try NameTemplate.names(from: "<[N2-4]|[N2,3]|[N-3-]|[N05-9]", context: context) == [
                "epo", "epo", "ort", "000rt"
            ]
        )
        for name in [
            "nametemplate-slice-overflow.bin", "nametemplate-slice-length-overflow.bin", "nametemplate-empty-name.bin"
        ] {
            let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fuzz/repro/diff/\(name)")
            guard let data = try? Data(contentsOf: file) else { continue }
            // Whatever the bytes say, as a typed name they must come back as names or an error.
            let names = try? NameTemplate.names(from: "<" + String(decoding: data, as: UTF8.self), context: context)
            #expect(names?.contains("") != true)
        }
    }

    // F035, F075
    @Test func aMaskThatComesToNothingNamesNothing() throws {
        let context = NameTemplate.Context()
        #expect(try NameTemplate.names(from: "<[T2+1D]", context: context).isEmpty)
        #expect(try NameTemplate.names(from: "<[T2+1D] | real", context: context) == ["real"])
        #expect(try NameTemplate.names(from: "<1-3>[T1]", context: context).isEmpty)
    }

    // F035, F074
    @Test func theDateFormattersAreMadeOncePerText() throws {
        var context = NameTemplate.Context()
        context.now = Date(timeIntervalSince1970: 1_700_000_000)
        let names = try NameTemplate.names(from: "<0-19999>[C] [d] [t]", context: context)
        #expect(names.count == 20_000 && Set(names).count == 20_000)
        let one = try NameTemplate.names(from: "<[d] [t]", context: context)
        #expect(names[7] == "00007 " + one[0] && !one[0].contains("/") && !one[0].contains(":"))
    }

    // F059
    @Test func theClipboardCannotBringPathsIntoAName() throws {
        var context = NameTemplate.Context()
        context.clipboard = "../../etc/passwd\nsecond line"
        #expect(try NameTemplate.names(from: "<[X]", context: context) == [".._.._etc_passwd"])
        context.clipboard = ".."
        #expect(try NameTemplate.names(from: "<[X]", context: context) == ["__"])
        context.clipboard = "~/secret"
        #expect(try NameTemplate.names(from: "<new [X]", context: context) == ["new __secret"])
        context.clipboard = "a:b*c\tend"
        #expect(try NameTemplate.names(from: "<[X]", context: context) == ["a_b_c_end"])
        context.clipboard = ""
        #expect(throws: NameTemplate.Failure.emptyClipboard) {
            _ = try NameTemplate.names(from: "<[X]", context: context)
        }
    }
}

@Suite struct Review2FileopsLog {
    let box: Sandbox

    init() throws {
        box = try Sandbox()
    }

    private func configuration(_ rotation: OperationLog.Rotation = .never) -> OperationLog.Configuration {
        var configuration = OperationLog.Configuration()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
        configuration.rotation = rotation
        configuration.keepCount = 0
        return configuration
    }

    // F060, F055
    @Test func aNameWithALineBreakIsOneLineInTheLog() {
        let forged = OperationRecord(
            .copy,
            source: "/a/x\n2026-01-01 00:00:00: Delete: /etc/passwd",
            target: "/b/y\r",
            status: .failed("no\nway")
        )
        let line = OperationLog.line(for: forged, at: "T")
        #expect(
            line
                == "T: Error: Copy: /a/x<U+000A>2026-01-01 00:00:00: Delete: /etc/passwd -> /b/y<U+000D>: no<U+000A>way\n"
        )
        #expect(line.filter { $0 == "\n" }.count == 1)
        #expect(
            OperationLog.line(for: OperationRecord(.delete, source: "/plain/ü name.txt"), at: "T")
                == "T: Delete: /plain/ü name.txt\n"
        )
    }

    // F061
    @Test func aBurstThatFillsTheLogSeveralTimesRotatesEachTime() throws {
        let log = OperationLog(configuration(.size(200)))
        // Twelve lines of 61 bytes in one burst: three fit into a file of 200 bytes.
        for index in 0..<12 {
            log.write(OperationRecord(.copy, source: "/source/folder/file-\(String(format: "%02d", index)).txt"))
        }
        log.flush()
        let files = namesOnDisk(box.url("logs"))
        #expect(files.count == 4, "\(files)")
        for name in files {
            let size =
                (try FileManager.default.attributesOfItem(atPath: box.url("logs/\(name)").path)[.size] as? Int) ?? 0
            #expect(size > 0 && size <= 200, "\(name): \(size)")
        }
    }

    // F062
    @Test func theLogAppendsAlsoAfterSomebodyElseEmptiedOrExtendedIt() throws {
        let log = OperationLog(configuration())
        log.write(OperationRecord(.copy, source: "/one"))
        #expect(log.flush(timeout: 30))
        // The handle is let go by `flush`; keep one open across the change with `flushSoon`.
        log.write(OperationRecord(.copy, source: "/two"))
        log.flushSoon()
        log.write(OperationRecord(.copy, source: "/wait"))
        log.flushSoon()
        let file = box.url("logs/operations.log")
        // Wait until the open handle has written, without closing it.
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        var text = ""
        for _ in 0..<2_000 where !text.contains("/wait") {
            text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if !text.contains("/wait") { usleep(5_000) }
        }
        try #require(text.contains("/wait"))
        // Another writer empties the file and writes a line of its own.
        try writer.truncate(atOffset: 0)
        try writer.write(contentsOf: Data("somebody else\n".utf8))
        log.write(OperationRecord(.copy, source: "/three"))
        log.flush()
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 2 && lines[0] == "somebody else" && lines[1].hasSuffix("Copy: /three"))
    }

    // F027
    @Test func theFlushAtQuitGivesUpAfterItsTime() throws {
        let log = OperationLog(configuration())
        log.write(OperationRecord(.copy, source: "/one"))
        #expect(log.flush(timeout: 30))
        #expect(try String(contentsOf: box.url("logs/operations.log"), encoding: .utf8).hasSuffix("Copy: /one\n"))
    }
}

/// A file system over memory whose reads wait until they are let go.
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
final class GatedFileSystem: FileSystemProvider, @unchecked Sendable {
    let base = MemoryFileSystem(scheme: "gated")
    var scheme: String { base.scheme }
    var capabilities: FileSystemCapabilities { [.write] }
    let entered = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var waits = false
    private var count = 0

    var reads: Int { lock.withLock { count } }
    func holdNextRead() { lock.withLock { waits = true } }

    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }
    func item(at url: URL) -> FileItem? { base.item(at: url) }
    func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    func read(_ url: URL) throws -> any FileReader {
        // The contents as they are now; handed out only after the gate opens.
        let reader = try base.read(url)
        let held: Bool = lock.withLock {
            count += 1
            defer { waits = false }
            return waits
        }
        if held {
            entered.signal()
            gate.wait()
        }
        return reader
    }
    func createDirectory(at url: URL) throws { base.createDirectory(at: url) }
    func write(_ url: URL) throws -> any FileWriter { try base.write(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
    }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
    }
}

@Suite struct Review2FileopsComments {
    // F077
    @Test func aFirstNameThatLooksLikeAByteOrderMarkStaysAName() throws {
        // `ÿþ` in the Windows code page is FF FE: the mark of UTF-16.
        var file = DescriptIon(data: Data([0x0A, 0xFF, 0xFE]) + Data("x one\r\nother two\r\n".utf8))
        #expect(file.entries.map(\.name) == ["ÿþx", "other"])
        file.setComment("changed", for: "other")
        let again = try #require(DescriptIon(strict: file.data()))
        #expect(again.entries == file.entries && again.encoding == .ansi)
        #expect(!file.data().starts(with: [0xFF, 0xFE]))
        // The same for a file in UTF-8 without a mark whose first name starts with U+FEFF.
        var utf8 = DescriptIon(data: Data("\r\n\u{FEFF}né one\r\n".utf8))
        #expect(utf8.entries.map(\.name) == ["\u{FEFF}né"])
        utf8.setComment("two", for: "b")
        #expect(DescriptIon(strict: utf8.data())?.entries == utf8.entries)
    }

    // F078
    @Test func separatorsAreFoundNextToCombiningMarks() {
        // A comment that starts with a combining accent, a name that ends with a format character.
        let file = DescriptIon(data: Data("x \u{0301}comment\r\n\"a b\"\u{0301} c\r\nn\u{0600} text\r\n".utf8))
        #expect(file.entries.count == 3)
        #expect(file.entries[0] == DescriptIon.Entry(name: "x", comment: "\u{0301}comment"))
        #expect(file.entries[1].name == "a b")
        #expect(file.entries[2].name == "n\u{0600}" && file.entries[2].comment == "text")
        #expect(DescriptIon(strict: file.data())?.entries.map(\.name) == ["x", "a b", "n\u{0600}"])
        var written = DescriptIon()
        written.setComment("\u{0301}accent first", for: "plain")
        written.setComment("two\nlines", for: "with space")
        #expect(DescriptIon(strict: written.data())?.entries == written.entries)
    }

    // F068
    @Test func aNameTheFileCannotHoldIsRefusedInsteadOfBeingReadBackAsAnother() throws {
        #expect(
            DescriptIon.canName("plain.txt") && DescriptIon.canName("with space.txt")
                && DescriptIon.canName("quote\"inside")
        )
        #expect(
            !DescriptIon.canName("line\nbreak") && !DescriptIon.canName("a \"b\" c") && !DescriptIon.canName("\"start")
                && !DescriptIon.canName("")
        )
        let memory = MemoryFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        memory.addFile("/A/descript.ion", "keep.txt kept\r\n")
        let store = CommentStore(fileSystems: fileSystems)
        #expect(throws: CommentFileError.self) {
            try store.setComment("x", for: "a \"b\" c", in: memory.url("/A"), hidden: false)
        }
        #expect(memory.contents("/A/descript.ion") == "keep.txt kept\r\n")
        // Taking a comment away is always possible.
        try store.setComment("", for: "a \"b\" c", in: memory.url("/A"), hidden: false)
        try store.setComment("fine", for: "quote\"inside", in: memory.url("/A"), hidden: false)
        #expect(store.comments(in: memory.url("/A")) == ["keep.txt": "kept", "quote\"inside": "fine"])
    }

    // F036, F065
    @Test func aReadingThatBeganBeforeAChangeIsNotRemembered() throws {
        let gated = GatedFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(gated)
        gated.base.addFile("/A/descript.ion", "a.txt old\r\n")
        let store = CommentStore(fileSystems: fileSystems)
        let folder = gated.base.url("/A")
        gated.holdNextRead()
        let first = DispatchSemaphore(value: 0)
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var stale: [String: String] = [:]
        Thread.detachNewThread {
            stale = store.comments(in: folder)
            first.signal()
        }
        // The reader has the old file in hand; now the comment changes.
        gated.entered.wait()
        try store.setComment("new", for: "a.txt", in: folder, hidden: false)
        gated.gate.signal()
        first.wait()
        #expect(stale == ["a.txt": "old"])
        // What was read before the change was not kept: the next question reads the file again.
        #expect(store.comments(in: folder) == ["a.txt": "new"])
    }

    // F066
    @Test func aPipeCalledLikeTheCommentFileIsNotRead() throws {
        let box = try Sandbox()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let pipe = box.url("d/descript.ion")
        try box.folder("d")
        #expect(mkfifo(pipe.path, 0o644) == 0)
        let store = CommentStore(fileSystems: fileSystems)
        let done = DispatchSemaphore(value: 0)
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var refused = false
        Thread.detachNewThread {
            _ = store.comments(in: box.url("d"))
            refused = (try? store.setComment("x", for: "a.txt", in: box.url("d"), hidden: false)) == nil
            done.signal()
        }
        let ended = done.wait(timeout: .now() + 60) == .success
        if !ended {
            // Let the reader that hangs go, so the test ends.
            let descriptor = open(pipe.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 { close(descriptor) }
            _ = done.wait(timeout: .now() + 10)
        }
        #expect(ended && refused)
    }

    // F067
    @Test func aLinkedOrHiddenCommentFileStaysLinkedAndHidden() throws {
        let box = try Sandbox()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let store = CommentStore(fileSystems: fileSystems)
        let real = try box.file("shared/descript.ion", "a.txt old\r\n")
        try box.folder("d")
        try FileManager.default.createSymbolicLink(at: box.url("d/descript.ion"), withDestinationURL: real)
        try store.setComment("new", for: "a.txt", in: box.url("d"), hidden: false)
        #expect(LocalInfo.isSymlink(box.url("d/descript.ion")) && box.read("shared/descript.ion") == "a.txt new\r\n")
        // Hidden by another program, with hiding switched off here: it stays hidden.
        let hidden = try box.file("h/descript.ion", "a.txt old\r\n")
        try LocalInfo.setFlag(UInt32(UF_HIDDEN), true, of: hidden)
        try store.setComment("new", for: "a.txt", in: box.url("h"), hidden: false)
        #expect(LocalInfo.details(hidden)?.isHidden == true && box.read("h/descript.ion") == "a.txt new\r\n")
    }
}

@MainActor @Suite struct Review2FileopsAttributes {
    // F028, F076
    @Test func anOctalModeIsTheWholeModeAsForChmod() {
        #expect(PermissionChange("755") == .absolute(0o755, keepingSpecialBits: false))
        #expect(PermissionChange("755")?.applied(to: 0o4755, isDirectory: false) == 0o755)
        #expect(PermissionChange("4755")?.applied(to: 0o644, isDirectory: false) == 0o4755)
        #expect(PermissionChange("0755")?.applied(to: 0o4755, isDirectory: false) == 0o755)
        // Letters cannot name the three special bits, and leave them.
        #expect(PermissionChange("rwxr-xr-x")?.applied(to: 0o4700, isDirectory: false) == 0o4755)
        #expect(PermissionChange("go-w")?.applied(to: 0o2777, isDirectory: true) == 0o2755)
    }

    // F069
    @Test func everyChangeCanBeWrittenAndReadBack() throws {
        for text in ["755", "4755", "rwxr-x---", "u+x,go-w", "a+rX", "o=", "ug+rw"] {
            let change = try #require(PermissionChange(text))
            #expect(PermissionChange(change.text) == change, "\(text) → \(change.text)")
        }
        let parsed = try #require(AttributeChange.parse(parameters: "+mu+x,go-w +f"))
        var draft = AttributeDraft(items: [
            FileItem(url: URL(fileURLWithPath: "/tmp/x"), name: "x", stat: .init(permissions: 0o644))
        ])
        draft.take(parsed.change)
        #expect(draft.permissions == "u+x,go-w" && draft.untouchedPermissions == nil)
        #expect(try draft.change(isLocal: true).get().permissions == parsed.change.permissions)
    }

    // F028: Recurse with the mode left as shown.
    @Test func recurseWithUntouchedPermissionsIsAskedAboutNotDroppedSilently() throws {
        var draft = AttributeDraft(items: [
            FileItem(url: URL(fileURLWithPath: "/tmp/d"), name: "d", kind: .directory, stat: .init(permissions: 0o750))
        ])
        draft.recurse = true
        let untouched = try draft.change(isLocal: true).get()
        #expect(draft.untouchedPermissions == "750" && untouched.isEmpty)
        draft.confirmPermissions()
        #expect(draft.untouchedPermissions == nil)
        #expect(try draft.change(isLocal: true).get().permissions == .absolute(0o750, keepingSpecialBits: false))
    }

    // F063, F064, F043
    @Test func changesStartFromWhatTheItemHasNowAndNeverUnlockOrFollowALink() throws {
        let box = try Sandbox()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let local = try #require(try? fileSystems.provider(for: box.root))
        // Listed with 644, made 600 by somebody else since: `u+x` gives 700, not 744.
        let file = try box.file("d/a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let listed = try #require(local.item(at: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var change = AttributeChange()
        change.permissions = try #require(PermissionChange("u+x"))
        var outcome = AttributeJob(change: change, fileSystems: fileSystems).run([listed])
        #expect(outcome.failed == 0 && LocalInfo.details(file)?.mode == 0o700)
        // A locked file with "Locked: unchanged" is reported and stays locked and as it was.
        let lockedFile = try box.file("d/locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: lockedFile.path)
        try LocalInfo.setFlag(UInt32(UF_IMMUTABLE), true, of: lockedFile)
        defer { try? LocalInfo.setFlag(UInt32(UF_IMMUTABLE), false, of: lockedFile) }
        change.permissions = try #require(PermissionChange("644"))
        outcome = AttributeJob(change: change, fileSystems: fileSystems).run([try #require(local.item(at: lockedFile))])
        #expect(
            outcome.failed == 1 && LocalInfo.details(lockedFile)?.isLocked == true
                && LocalInfo.details(lockedFile)?.mode == 0o444
        )
        // With "Locked: clear" the same change goes through.
        change.locked = false
        outcome = AttributeJob(change: change, fileSystems: fileSystems).run([try #require(local.item(at: lockedFile))])
        #expect(outcome.failed == 0 && LocalInfo.details(lockedFile)?.mode == 0o644)
        // Listed as a file, replaced by a link since: the link's target keeps its mode.
        let victim = try box.file("private/key", "k")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: victim.path)
        let swapped = try box.file("d/swap.txt")
        let before = try #require(local.item(at: swapped))
        try FileManager.default.removeItem(at: swapped)
        try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: victim)
        change = AttributeChange()
        change.permissions = try #require(PermissionChange("777"))
        _ = AttributeJob(change: change, fileSystems: fileSystems).run([before])
        #expect(LocalInfo.details(victim)?.mode == 0o600)
    }

    // F029, F030
    @Test func aLongListOfFailuresIsCutForTheMessage() {
        let failures = (0..<20).map { "item \($0): no" }
        let text = PropertyActions.summary(of: failures, total: 300_000)
        #expect(text.split(separator: "\n").count == 21 && text.hasSuffix("… and 299980 more"))
        #expect(PropertyActions.summary(of: ["one: no"]) == "one: no")
    }
}
