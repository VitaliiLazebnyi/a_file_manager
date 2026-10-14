import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing
import VirtualFoldersPlugin

@testable import FileOperationsPlugin

// The data-loss defects of review round 2 (F001/F018, F006/F013, F022/F033, F012/F020), each as
// the smallest scenario that lost data. This file uses nothing that the program did not have
// before the round, so it also compiles against the sources as they were then
// (build/backups/before-round2-fixes.tgz): there every test here fails, which is the proof
// that the tests see the defects and not just the fixes.

/// Says yes to everything a job asks that existed before the round, and nothing else: the
/// question about another volume is left to the protocol's default.
private final class OldAnswers: FileJobDelegate {
    private let lock = NSLock()
    private var messages: [String] = []
    let conflict: ConflictChoice

    init(conflict: ConflictChoice = .overwrite) { self.conflict = conflict }

    var errors: [String] { lock.withLock { messages } }

    func job(_ job: FileJob, progress: JobProgress) {}
    func job(_ job: FileJob, conflictAt target: FileItem, source: FileItem) -> ConflictChoice { conflict }
    func job(_ job: FileJob, failedAt url: URL, error: Error) -> ErrorChoice {
        lock.withLock { messages.append(error.localizedDescription) }
        return .skip
    }
    func job(_ job: FileJob, confirmDeleteNonEmpty directory: URL) -> FolderDeleteChoice { .delete }
}

private func names(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

@Suite(.serialized) struct Review2FileopsP2DataLoss {
    let box: Sandbox
    let fileSystems = FileSystemRegistry()
    let virtual: VirtualFileSystem

    init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
        virtual = VirtualFileSystem(fileSystems: fileSystems)
        fileSystems.register(virtual)
    }

    // F001, F018: the target is the file's own folder, named through the branch view. Before:
    // the file was copied onto itself and then removed as the source of the move.
    @Test func aMoveWithinABranchViewNeverRemovesTheFile() throws {
        let file = try box.file("d/a.txt", "precious")
        let job = FileJob(
            kind: .move, sources: [file], target: TargetSpec(directory: virtual.branch(of: box.url("d"))),
            fileSystems: fileSystems)
        let answers = OldAnswers()
        job.delegate = answers
        _ = job.run()
        #expect(box.read("d/a.txt") == "precious")
        #expect(names(in: box.url("d")) == ["a.txt"])
    }

    // F006, F013: two files of one name from two folders, moved into one folder under
    // "Overwrite all". Before: the second overwrote the first, and both sources were gone.
    @Test func twoSourcesOfOneNameBothSurviveAMoveUnderOverwriteAll() throws {
        let sources = [try box.file("s/a/x.txt", "from-a"), try box.file("s/b/x.txt", "from-b")]
        try box.folder("t")
        let job = FileJob(
            kind: .move, sources: sources, target: TargetSpec(directory: box.url("t")), fileSystems: fileSystems)
        job.options.overwrite = .overwriteAll
        let answers = OldAnswers()
        job.delegate = answers
        _ = job.run()
        // Wherever they are now, both contents still exist.
        var contents: Set<String> = []
        for folder in ["t", "s/a", "s/b"] {
            for name in names(in: box.url(folder)) {
                if let text = box.read("\(folder)/\(name)") { contents.insert(text) }
            }
        }
        #expect(contents == ["from-a", "from-b"])
    }

    // The same through a mask that gives three sources one name.
    @Test func aMaskThatGivesThreeSourcesOneNameLosesNone() throws {
        let sources = [
            try box.file("s/a.doc", "doc"), try box.file("s/a.pdf", "pdf"), try box.file("s/a.rtf", "rtf")
        ]
        try box.folder("t")
        let job = FileJob(
            kind: .move, sources: sources, target: TargetSpec(directory: box.url("t"), mask: "*.txt"),
            fileSystems: fileSystems)
        job.options.overwrite = .overwriteAll
        let answers = OldAnswers()
        job.delegate = answers
        _ = job.run()
        var contents: Set<String> = []
        for folder in ["t", "s"] {
            for name in names(in: box.url(folder)) {
                if let text = box.read("\(folder)/\(name)") { contents.insert(text) }
            }
        }
        #expect(contents == ["doc", "pdf", "rtf"])
    }

    // F022, F033: the target name is a link to another file. Before: Resume cut that file and
    // wrote the source over it.
    @Test func resumeNeverWritesThroughALinkAtTheTarget() throws {
        let kept = "the victim's own contents"
        let victim = try box.file("elsewhere/victim.txt", kept)
        let source = try box.file("s/f.txt", String(repeating: "source-bytes ", count: 20))
        try box.folder("t")
        try FileManager.default.createSymbolicLink(at: box.url("t/f.txt"), withDestinationURL: victim)
        let job = FileJob(
            kind: .copy, sources: [source], target: TargetSpec(directory: box.url("t")), fileSystems: fileSystems)
        let answers = OldAnswers(conflict: .resume)
        job.delegate = answers
        _ = job.run()
        #expect(box.read("elsewhere/victim.txt") == kept)
    }

    // F012, F020: a disk image mounted inside the folder that is deleted for good, and nobody
    // says that the volume is meant too. Before: everything on the volume was deleted.
    @Test func deletingAFolderLeavesAVolumeMountedInsideItAlone() throws {
        let mount = box.url("tree/mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try box.file("tree/beside.txt", "outside")
        func hdiutil(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
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
        let job = FileJob(kind: .delete(toTrash: false), sources: [box.url("tree")], fileSystems: fileSystems)
        let answers = OldAnswers()
        job.delegate = answers
        _ = job.run()
        #expect((try? String(contentsOf: precious, encoding: .utf8)) == "on the volume")
    }
}
