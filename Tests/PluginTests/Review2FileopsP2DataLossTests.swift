import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing
import VirtualFoldersPlugin

@testable import FileOperationsPlugin

/// The data-loss defects of review round 2, each as the smallest scenario that lost data.
///
/// This suite uses nothing that the program did not have before the round, so it also compiles against the sources
/// as they were then (build/backups/before-round2-fixes.tgz): there every test here fails, which is the proof that
/// the tests see the defects and not just the fixes.
@Suite(.serialized)
internal struct Review2FileopsP2DataLossTests {
    /// Says yes to everything a job asks that existed before the round, and nothing else: the
    /// question about another volume is left to the protocol's default.
    private final class OldAnswers: FileJobDelegate {
        private let lock = NSLock()
        private var messages: [String] = []
        let conflict: ConflictChoice

        var errors: [String] { lock.withLock { messages } }

        init(conflict: ConflictChoice) { self.conflict = conflict }

        func job(_: FileJob, progress _: JobProgress) {
            // Progress is not checked here.
        }
        func job(_: FileJob, conflictAt _: FileItem, source _: FileItem) -> ConflictChoice { conflict }
        func job(_: FileJob, failedAt _: URL, error: any Error) -> ErrorChoice {
            lock.withLock { messages.append(error.localizedDescription) }
            return .skip
        }
        func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice { .delete }

        deinit {
            // Nothing to release.
        }
    }

    /// The temporary folder the files are made in.
    internal let box: Sandbox
    /// The file systems the jobs see: the local one and the virtual folders over it.
    internal let fileSystems = FileSystemRegistry()
    /// The virtual folders, for the branch view.
    internal let virtual: VirtualFileSystem

    /// A sandbox and the local and virtual file systems.
    internal init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
        virtual = VirtualFileSystem(fileSystems: fileSystems)
        fileSystems.register(virtual)
    }

    /// The names in `folder`, sorted; none when it cannot be read.
    private static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// A move into the file's own folder, named through the branch view, never removes the file.
    ///
    /// F001, F018: before, the file was copied onto itself and then removed as the source of the move.
    @Test
    internal func aMoveWithinABranchViewNeverRemovesTheFile() throws {
        let file = try box.file("d/a.txt", "precious")
        let job = FileJob(
            kind: .move,
            sources: [file],
            target: TargetSpec(directory: virtual.branch(of: box.url("d"))),
            fileSystems: fileSystems
        )
        let answers = OldAnswers(conflict: .overwrite)
        job.delegate = answers
        _ = job.run()
        #expect(box.read("d/a.txt") == "precious")
        #expect(Self.names(in: box.url("d")) == ["a.txt"])
    }

    /// Two files of one name from two folders, moved into one folder under "Overwrite all", both survive.
    ///
    /// F006, F013: before, the second overwrote the first, and both sources were gone.
    @Test
    internal func twoSourcesOfOneNameBothSurviveAMoveUnderOverwriteAll() throws {
        let sources = [try box.file("s/a/x.txt", "from-a"), try box.file("s/b/x.txt", "from-b")]
        try box.folder("t")
        let job = FileJob(
            kind: .move,
            sources: sources,
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.options.overwrite = .overwriteAll
        let answers = OldAnswers(conflict: .overwrite)
        job.delegate = answers
        _ = job.run()
        // Wherever they are now, both contents still exist.
        var contents: Set<String> = []
        for folder in ["t", "s/a", "s/b"] {
            for name in Self.names(in: box.url(folder)) {
                if let text = box.read("\(folder)/\(name)") { contents.insert(text) }
            }
        }
        #expect(contents == ["from-a", "from-b"])
    }

    /// A move through a mask that gives three sources one name loses none of them.
    @Test
    internal func aMaskThatGivesThreeSourcesOneNameLosesNone() throws {
        let sources = [
            try box.file("s/a.doc", "doc"), try box.file("s/a.pdf", "pdf"), try box.file("s/a.rtf", "rtf")
        ]
        try box.folder("t")
        let job = FileJob(
            kind: .move,
            sources: sources,
            target: TargetSpec(directory: box.url("t"), mask: "*.txt"),
            fileSystems: fileSystems
        )
        job.options.overwrite = .overwriteAll
        let answers = OldAnswers(conflict: .overwrite)
        job.delegate = answers
        _ = job.run()
        var contents: Set<String> = []
        for folder in ["t", "s"] {
            for name in Self.names(in: box.url(folder)) {
                if let text = box.read("\(folder)/\(name)") { contents.insert(text) }
            }
        }
        #expect(contents == ["doc", "pdf", "rtf"])
    }

    /// Resume never writes through a link that stands at the target name.
    ///
    /// F022, F033: before, Resume cut the file the link points to and wrote the source over it.
    @Test
    internal func resumeNeverWritesThroughALinkAtTheTarget() throws {
        let kept = "the victim's own contents"
        let victim = try box.file("elsewhere/victim.txt", kept)
        let source = try box.file("s/f.txt", String(repeating: "source-bytes ", count: 20))
        try box.folder("t")
        try FileManager.default.createSymbolicLink(at: box.url("t/f.txt"), withDestinationURL: victim)
        let job = FileJob(
            kind: .copy,
            sources: [source],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        let answers = OldAnswers(conflict: .resume)
        job.delegate = answers
        _ = job.run()
        #expect(box.read("elsewhere/victim.txt") == kept)
    }

    /// Deleting a folder for good leaves a disk image mounted inside it alone when nobody says the volume is meant.
    ///
    /// F012, F020: before, everything on the volume was deleted.
    @Test
    internal func deletingAFolderLeavesAVolumeMountedInsideItAlone() throws {
        let mount = box.url("tree/mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try box.file("tree/beside.txt", "outside")
        func hdiutil(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        // Where images cannot be attached there is nothing to check.
        guard hdiutil(["create", "-size", "4m", "-fs", "HFS+", "-volname", "afmp2", box.url("disk.dmg").path]),
            hdiutil(["attach", box.url("disk.dmg").path, "-mountpoint", mount.path, "-nobrowse", "-noautoopen"])
        else { return }
        defer { _ = hdiutil(["detach", mount.path, "-force"]) }
        let precious = mount.appendingPathComponent("precious.txt")
        try "on the volume".write(to: precious, atomically: true, encoding: .utf8)
        let job = FileJob(
            kind: .delete(toTrash: false),
            sources: [box.url("tree")],
            target: nil,
            fileSystems: fileSystems
        )
        let answers = OldAnswers(conflict: .overwrite)
        job.delegate = answers
        _ = job.run()
        #expect((try? String(contentsOf: precious, encoding: .utf8)) == "on the volume")
    }
}
