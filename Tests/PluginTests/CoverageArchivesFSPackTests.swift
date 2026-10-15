import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Pack, Unpack and Test with answers the other suites do not give: nothing to work on, a
/// dialog that is cancelled, values out of range, passwords that are empty or differ,
/// archives that cannot be read, and long lists of problems.
@MainActor
@Suite
internal struct CoverageArchivesFSPackTests {
    private let box: Sandbox
    private let memory = MemoryFileSystem()
    private let settings = MemorySettings()
    private let archives = ArchivesPlugin(flushDelay: nil, launchesApplications: false)
    private let bench: TestBench

    private var interaction: ScriptedInteraction { bench.interaction }
    private var left: FakePanel { bench.left }
    private var commands: CommandRegistry { bench.commands }

    private var actions: ArchiveCommands {
        ArchiveCommands(kernel: bench.kernel, store: archives.store, openFile: nil) { nil }
    }

    /// Files and archives in the left panel, an empty folder in the right one.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/tree/readme.txt", "read me")
        try box.file("A/notes.txt", "notes")
        try box.file("A/todo.txt", "todo")
        try box.folder("B")
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "tree"], in: box.url("A")).status == 0)
        #expect(runTool("/usr/bin/tar", ["-czf", "tree.tgz", "tree"], in: box.url("A")).status == 0)
        bench = TestBench(
            plugins: [NavigationPlugin(), archives],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
    }

    private func enter(_ name: String) {
        left.focus()
        left.moveCursor(toName: name)
        commands.perform(.open)
    }

    private func listed(_ path: String) -> [String] {
        runTool("/usr/bin/unzip", ["-Z1", box.url(path).path]).output.split(separator: "\n").map(String.init)
    }

    // MARK: Pack

    /// Pack, Unpack and Test with nothing to work on say so, and do nothing more.
    @Test
    internal func nothingToWorkOnIsSaid() {
        left.show(box.url("B"))
        actions.pack(move: false)
        actions.unpack()
        #expect(interaction.log == ["inform: No files selected!", "inform: No files selected!"])
        // Test with only a folder under the cursor: there is no file to test.
        left.show(box.url("A"))
        left.moveCursor(toName: "tree")
        commands.perform(.testArchive)
        #expect(interaction.log.last == "inform: No files selected!" && bench.jobService.titles.isEmpty)
    }

    /// A stored packer that no longer exists falls back to the first; a cancelled dialog packs
    /// nothing.
    @Test
    internal func aStoredPackerThatIsGoneFallsBackToZIP() throws {
        settings.set(99, forKey: ArchiveSettings.format)
        left.moveCursor(toName: "notes.txt")
        commands.perform(.packFiles)
        let fields = try #require(interaction.forms.last)
        #expect(fields.first?.initialValue == .text(box.url("B").path + "/notes.zip"))
        let written = try FileManager.default.contentsOfDirectory(atPath: box.url("B").path)
        #expect(bench.jobService.titles.isEmpty && written.isEmpty)
    }

    /// Several files in the top folder of a file system are proposed as "archive", in a target
    /// folder whose shown path ends with `/`.
    @Test
    internal func severalFilesInATopFolderAreProposedAsArchive() throws {
        _ = memory.addFile("/one.txt", "one")
        _ = memory.addFile("/two.txt", "two")
        left.show(memory.url("/"))
        bench.right.show(memory.url("/"))
        left.focus()
        left.model.selectAll()
        commands.perform(.packFiles)
        let fields = try #require(interaction.forms.last)
        #expect(fields.first?.initialValue == .text("mem:/archive.zip"))
    }

    /// A packer that is no choice of the dialog packs a ZIP; an empty name packs into the
    /// folder of the files, named after the first.
    @Test
    internal func unknownChoicesAndEmptyNamesPackAZIPBesideTheFiles() {
        left.moveCursor(toName: "notes.txt")
        interaction.formAnswers = [.values(["format": .index(99), "archive": .text(box.url("B/odd").path)])]
        commands.perform(.packFiles)
        #expect(listed("B/odd.zip") == ["notes.txt"])
        interaction.formAnswers = [.values(["archive": .text("")])]
        commands.perform(.packFiles)
        #expect(listed("A/notes.zip") == ["notes.txt"])
    }

    /// A path through an archive that cannot be changed is refused with a message.
    @Test
    internal func packingIntoAnArchiveThatCannotBeChangedIsRefused() {
        left.moveCursor(toName: "notes.txt")
        interaction.formAnswers = [.values(["archive": .text(box.url("A/tree.tgz").path + "/tree")])]
        commands.perform(.packFiles)
        #expect(interaction.log.last == "inform: tree.tgz cannot be changed." && bench.jobService.titles.isEmpty)
    }

    /// The password of a new archive must not be empty and must be typed twice alike; AES is
    /// the encryption unless the old one is asked for; cancelling the question packs nothing.
    @Test
    internal func thePasswordOfANewArchiveIsAskedUntilItIsUsable() throws {
        left.moveCursor(toName: "notes.txt")
        interaction.formAnswers = [.values(["encrypt": .flag(true), "archive": .text(box.url("B/never").path)])]
        commands.perform(.packFiles)
        #expect(interaction.log.suffix(2) == ["form: Pack files", "form: Encrypt"] && bench.jobService.titles.isEmpty)
        interaction.formAnswers = [
            .values(["encrypt": .flag(true), "archive": .text(box.url("B/aes").path)]),
            .values(["password": .text(""), "repeat": .text("")]),
            .values(["password": .text("one"), "repeat": .text("two")]),
            .values(["password": .text("sesame"), "repeat": .text("sesame")])
        ]
        commands.perform(.packFiles)
        #expect(interaction.log.suffix(4) == ["form: Pack files", "form: Encrypt", "form: Encrypt", "form: Encrypt"])
        let archive = try archives.store.archive(at: box.url("B/aes.zip"))
        #expect(archive.entry("notes.txt")?.isEncrypted == true)
        if case .zip(let record)? = archive.entry("notes.txt")?.content {
            #expect(record.method == 99)
        } else {
            Issue.record("notes.txt is no ZIP member")
        }
    }

    /// A typed name that already ends like the chosen format keeps its ending.
    @Test
    internal func aNameThatEndsLikeTheFormatKeepsItsEnding() {
        #expect(ArchiveCommands.archiveName("backup.tgz", format: .compressedTar(.gzip)) == "backup.tgz")
        #expect(ArchiveCommands.archiveName("backup.tgz", format: .tar) == "backup.tar")
    }

    // MARK: Unpack

    /// A cancelled dialog unpacks nothing; an empty mask unpacks everything.
    @Test
    internal func anEmptyMaskUnpacksEverything() {
        left.moveCursor(toName: "tree.zip")
        commands.perform(.unpackFiles)
        #expect(bench.jobService.titles.isEmpty)
        interaction.formAnswers = [.values(["mask": .text("  "), "target": .text(box.url("B/out").path)])]
        commands.perform(.unpackFiles)
        #expect(box.read("B/out/tree/readme.txt") == "read me")
    }

    /// Inside an archive whose file is gone, nothing can be unpacked, and that is said.
    @Test
    internal func unpackingFromAnArchiveThatIsGoneFails() throws {
        enter("tree.zip")
        enter("tree")
        try FileManager.default.removeItem(at: box.url("A/tree.zip"))
        interaction.formAnswers = [.values(["target": .text(box.url("B").path)])]
        commands.perform(.unpackFiles)
        #expect(interaction.log.last == "inform: Unpacking failed!")
    }

    /// Many files that are no archives make a long list of problems, of which the message
    /// shows the first twelve and the number of the others.
    @Test
    internal func aLongListOfProblemsIsShortened() throws {
        for index in 1...13 {
            try box.file("A/plain\(index).txt", "not an archive")
        }
        left.reload()
        left.model.select(mask: "plain*.txt")
        interaction.formAnswers = [.values(["target": .text(box.url("B").path)])]
        commands.perform(.unpackFiles)
        #expect(interaction.log.last == "inform: Unpacking failed!")
        let problems = (1...13).map { "problem \($0)" }
        let summary = ArchiveCommands.summary(of: problems)
        #expect(summary == problems.prefix(12).joined(separator: "\n") + "\n… and 1 more")
        #expect(ArchiveCommands.summary(of: ["one"]) == "one")
    }

    // MARK: Test

    /// A file that is no archive is a problem of the test.
    @Test
    internal func testingAFileThatIsNoArchiveFindsAnError() {
        left.moveCursor(toName: "notes.txt")
        commands.perform(.testArchive)
        #expect(interaction.log.last == "inform: Errors found in archive!")
    }
}
