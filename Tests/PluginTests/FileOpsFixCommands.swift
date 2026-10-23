import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ClipboardPlugin
@testable import FileOperationsPlugin
@testable import FilePropertiesPlugin
@testable import MacIntegrationPlugin

/// The commands of the plugins, through a kernel with fake panels.
@MainActor
@Suite
internal struct FileOpsFixCommands {
    // MARK: F3

    /// The rename command changes only the letter case of a name without a question.
    @Test
    internal func aCaseOnlyRenameWorksAndNeverReplacesAnotherFile() throws {
        let box = try Sandbox()
        try box.file("A/readme", "mine")
        try box.folder("B")
        let bench = TestBench(
            plugins: [FileOperationsPlugin()],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.moveCursor(toName: "readme")
        bench.commands.perform(.renameOnly, .text("README"))
        #expect(namesOnDisk(box.url("A")) == ["README"] && box.read("A/README") == "mine")
        #expect(!bench.interaction.log.contains { $0.hasPrefix("inform") })
    }

    /// Where two names differ only in case, renaming one onto the other is refused.
    @Test
    internal func renamingOntoAnotherFileWhoseNameDiffersInCaseIsRefused() {
        // A file system that tells the two names apart, as a case-sensitive volume does.
        let memory = MemoryFileSystem()
        memory.addFile("/A/readme", "first")
        memory.addFile("/A/README", "second")
        let bench = TestBench(
            plugins: [FileOperationsPlugin()],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/A")
        )
        bench.left.moveCursor(toName: "readme")
        bench.commands.perform(.renameOnly, .text("README"))
        #expect(memory.contents("/A/readme") == "first" && memory.contents("/A/README") == "second")
        #expect(bench.interaction.log.contains("inform: readme cannot be renamed!"))
    }

    // MARK: F17

    /// Paste is offered only while files are on the clipboard.
    @Test
    internal func pasteIsOfferedWhileFilesAreOnTheClipboard() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("B")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bench = TestBench(
            plugins: [FileOperationsPlugin(), ClipboardPlugin(pasteboard: pasteboard)],
            fileSystems: [LocalFileSystem()],
            left: box.url("B"),
            right: box.url("A")
        )
        pasteboard.clearContents()
        #expect(!bench.commands.isEnabled(.pasteFromClipboard))
        let item = NSPasteboardItem()
        item.setString(box.url("A/one.txt").absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])
        #expect(bench.commands.isEnabled(.pasteFromClipboard))
    }

    /// The toolbar asks whether the Mac commands apply without building the list of marked items.
    @Test
    internal func theToolbarAsksWithoutBuildingTheListOfOperands() throws {
        let box = try Sandbox()
        for index in 0..<2_000 { try box.file("A/f\(index).txt", "x") }
        try box.folder("B")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let mac = MacIntegrationPlugin(launchesApplications: false, pasteboard: pasteboard) { _ in [] }
        let bench = TestBench(
            plugins: [SelectionPlugin(), mac],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.model.selectAll()
        #expect(
            bench.commands.isEnabled(MacIntegrationPlugin.quickLook)
                && bench.commands.isEnabled(MacIntegrationPlugin.share)
                && bench.commands.isEnabled(MacIntegrationPlugin.editTags)
        )
        bench.left.model.clearSelection()
        bench.left.model.moveCursor(to: 0)
        #expect(!bench.commands.isEnabled(MacIntegrationPlugin.quickLook))
    }

    // MARK: F18

    /// Saving details never removes a folder of that name and replaces a file in one step.
    @Test
    internal func savingDetailsKeepsTheOldFileUntilTheNewOneIsThereAndNeverRemovesAFolder() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.folder("A/details.txt")
        try box.file("A/details.txt/inside", "precious")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bench = TestBench(
            plugins: [ClipboardPlugin(pasteboard: pasteboard)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("A")
        )
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform(ClipboardCommands.saveDetails, .text("details.txt"))
        #expect(box.read("A/details.txt/inside") == "precious")
        #expect(bench.interaction.log.contains("inform: The details cannot be saved!"))

        // A file is replaced in one step, without a leftover.
        try box.file("A/notes.txt", "old")
        bench.interaction.choiceAnswers = [0]
        bench.commands.perform(ClipboardCommands.saveDetails, .text("notes.txt"))
        #expect(box.read("A/notes.txt")?.hasPrefix("one.txt\t") == true)
        #expect(!namesOnDisk(box.url("A")).contains { $0.hasSuffix(".tmp") })
    }

    // MARK: F19

    /// What the Mac plugin records for tests stays bounded however often it is used.
    @Test
    internal func theTestRecordsOfTheMacPluginStayBounded() throws {
        let box = try Sandbox()
        try box.file("A/notes.txt", "n")
        try box.folder("B")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let mac = MacIntegrationPlugin(launchesApplications: false, pasteboard: pasteboard) { _ in [] }
        let bench = TestBench(
            plugins: [SelectionPlugin(), mac],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.moveCursor(toName: "notes.txt")
        for _ in 0..<1_000 { bench.commands.perform(MacIntegrationPlugin.openWithDefault) }
        #expect(mac.opened.count <= 256 && mac.log.count <= 512 && mac.log.last?.hasPrefix("open ") == true)
    }

    // MARK: F2

    /// Changing only the date of a folder, recursively, leaves the permissions below it alone.
    @Test
    internal func changingOnlyTheDateOfAFolderLeavesThePermissionsBelowAlone() throws {
        let box = try Sandbox()
        let inner = try box.file("A/docs/in.txt", "inside")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inner.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.url("A/docs").path)
        try box.folder("B")
        let bench = TestBench(
            plugins: [FilePropertiesPlugin(launchesApplications: false)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.moveCursor(toName: "docs")
        // The permissions field keeps what the dialog proposed.
        bench.interaction.formAnswers = [
            .values([
                "recurse": .flag(true), "changeDate": .flag(true), "date": .text("2001-02-03"),
                "time": .text("04:05:06")
            ])
        ]
        bench.commands.perform(.setAttributes)
        #expect(bench.interaction.forms[0].first { $0.key == "permissions" }?.initialValue == .text("755"))
        #expect(LocalInfo.details(inner)?.mode == 0o600)
        let year = Calendar.current.component(
            .year,
            from: (try? FileManager.default.attributesOfItem(atPath: inner.path)[.modificationDate] as? Date) ?? Date()
        )
        #expect(year == 2_001)
    }

    /// OK in the attributes dialog of a locked file leaves it locked.
    @Test
    internal func pressingOKOnALockedFileDoesNotUnlockIt() throws {
        let box = try Sandbox()
        let file = try box.file("A/one.txt", "1")
        try box.folder("B")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }
        let bench = TestBench(
            plugins: [FilePropertiesPlugin(launchesApplications: false)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.moveCursor(toName: "one.txt")
        bench.interaction.formAnswers = [.accept]
        bench.commands.perform(.setAttributes)
        #expect((LocalInfo.details(file)?.flags ?? 0) & UInt32(UF_IMMUTABLE) != 0)
    }

    /// Permissions loaded from the target file are applied.
    @Test
    internal func permissionsTypedOrLoadedAreStillApplied() throws {
        let box = try Sandbox()
        let file = try box.file("A/one.txt", "1")
        try box.file("B/other.txt", "2")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: box.url("B/other.txt").path)
        let bench = TestBench(
            plugins: [FilePropertiesPlugin(launchesApplications: false)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.moveCursor(toName: "one.txt")
        bench.right.moveCursor(toName: "other.txt")
        // "Load from Target File" applies what it loaded, even though it is another file's mode.
        bench.interaction.formAnswers = [.values([:], button: 1), .accept]
        bench.commands.perform(.setAttributes)
        #expect(LocalInfo.details(file)?.mode == 0o640)
    }

    // MARK: F16

    /// A comment file that cannot be read or decoded is never overwritten.
    @Test
    internal func aCommentFileThatCannotBeReadIsNeverOverwritten() throws {
        let box = try Sandbox()
        try box.file("A/one.txt", "1")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let store = CommentStore(fileSystems: fileSystems)

        // Absent: the comment is simply created.
        try store.setComment("hello", for: "one.txt", in: box.url("A"), hidden: false)
        #expect(box.exists("A/descript.ion"))

        // Not decodable (a UTF-8 mark followed by bytes that are no UTF-8).
        let broken = Data([0xEF, 0xBB, 0xBF, 0xFF, 0xFE, 0xC0])
        try broken.write(to: box.url("A/descript.ion"))
        #expect(throws: (any Error).self) {
            try store.setComment("x", for: "one.txt", in: box.url("A"), hidden: false)
        }
        #expect(try Data(contentsOf: box.url("A/descript.ion")) == broken)

        // Unreadable.
        try box.file("B/descript.ion", "two.txt keep me\r\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: box.url("B/descript.ion").path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: box.url("B/descript.ion").path
            )
        }
        #expect(throws: (any Error).self) {
            try store.setComment("x", for: "other.txt", in: box.url("B"), hidden: false)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.url("B/descript.ion").path)
        #expect(box.read("B/descript.ion") == "two.txt keep me\r\n")
    }

    /// A comment file too large to read is not overwritten.
    @Test
    internal func anOversizedCommentFileIsNotOverwritten() throws {
        let memory = MemoryFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        memory.addFile("/A/descript.ion", String(repeating: "x", count: 17 * 1_024 * 1_024))
        let store = CommentStore(fileSystems: fileSystems)
        #expect(throws: (any Error).self) {
            try store.setComment("x", for: "one.txt", in: memory.url("/A"), hidden: false)
        }
        #expect(memory.contents("/A/descript.ion")?.count == 17 * 1_024 * 1_024)
    }

    // MARK: F12

    /// The allocated size is measured only when it is wanted.
    @Test
    internal func theAllocatedSizeIsOnlyAskedForWhenItIsWanted() throws {
        let box = try Sandbox()
        let file = try box.file("A/small.txt", "x")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let item = try #require(fileSystems.item(at: file))
        let lean = SpaceCalculator(fileSystems: fileSystems, measuresAllocated: false).measure([item])[0]
        let full = SpaceCalculator(fileSystems: fileSystems).measure([item])[0]
        #expect(lean.bytes == 1 && lean.allocated == 1)
        #expect(full.allocated >= 1 && full.allocated.isMultiple(of: 512))
    }
}
