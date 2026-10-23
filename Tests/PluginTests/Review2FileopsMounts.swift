import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// Deleting and moving across a mount point, with a real disk image.
///
/// Where the system does not let a test make or attach one (a sandbox), the suite has nothing to
/// say.
@Suite(.serialized)
internal struct Review2FileopsMounts {
    /// A scratch folder with tree/beside.txt and the mount point tree/mnt.
    internal let box: Sandbox
    /// Where the disk image is attached: tree/mnt.
    internal let mount: URL
    /// Whether the disk image could be made and attached; false in a sandbox.
    internal let attached: Bool

    /// A tree with a small disk image attached inside it, holding precious.txt, where the system allows it.
    internal init() throws {
        box = try Sandbox()
        mount = box.url("tree/mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try "outside".write(to: box.url("tree/beside.txt"), atomically: true, encoding: .utf8)
        let image = box.url("disk.dmg")
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
        attached =
            hdiutil(["create", "-size", "4m", "-fs", "HFS+", "-volname", "afmtest", image.path])
            && hdiutil(["attach", image.path, "-mountpoint", mount.path, "-nobrowse", "-noautoopen"])
        if attached {
            try "on the volume"
                .write(
                    to: mount.appendingPathComponent("precious.txt"),
                    atomically: true,
                    encoding: .utf8
                )
        }
    }

    private func detach() {
        guard attached else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mount.path, "-force"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // F012, F020
    /// Deleting a folder leaves a volume mounted inside it alone, unasked or answered with Skip.
    @Test
    internal func deletingAFolderDoesNotGoIntoAVolumeMountedInsideIt() {
        defer { detach() }
        guard attached else {
            return
        }
        let fileSystems = makeFileSystems().0
        #expect(FileIdentity.isMountPoint(mount) && !FileIdentity.isMountPoint(box.url("tree")))
        // Nobody answers the question (the default says no): the volume is left alone and that is noted.
        let quiet = Answers()
        var job = FileJob(
            kind: .delete(toTrash: false),
            sources: [box.url("tree")],
            target: nil,
            fileSystems: fileSystems
        )
        job.delegate = quiet
        var result = job.run()
        #expect(FileManager.default.fileExists(atPath: mount.appendingPathComponent("precious.txt").path))
        #expect(
            result.completed.isEmpty && result.failureCount == 1
                && result.failures.first?.contains("another volume") == true
        )
        #expect(!box.exists("tree/beside.txt"))
        // Asked, and answered with Skip.
        let replies = Review2Replies()
        replies.volume = .skip
        job = FileJob(kind: .delete(toTrash: false), sources: [box.url("tree")], target: nil, fileSystems: fileSystems)
        job.delegate = replies
        result = job.run()
        #expect(
            replies.volumes == ["mnt"]
                && FileManager.default.fileExists(atPath: mount.appendingPathComponent("precious.txt").path)
        )
    }

    /// Moving a folder item by item leaves a volume mounted inside it as it was.
    @Test
    internal func movingAFolderDoesNotEmptyAVolumeMountedInsideIt() throws {
        defer { detach() }
        guard attached else {
            return
        }
        let fileSystems = makeFileSystems().0
        // The target folder exists, so the move goes item by item.
        try box.folder("t/tree")
        let replies = Review2Replies()
        replies.volume = .skip
        let job = FileJob(
            kind: .move,
            sources: [box.url("tree")],
            target: TargetSpec(directory: box.url("t")),
            fileSystems: fileSystems
        )
        job.delegate = replies
        let result = job.run()
        #expect(replies.volumes == ["mnt"] && result.completed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: mount.appendingPathComponent("precious.txt").path))
        #expect(box.read("t/tree/beside.txt") == "outside" && !box.exists("t/tree/mnt/precious.txt"))
    }

    /// With an explicit yes, deleting the folder enters the mounted volume too.
    @Test
    internal func withAnExplicitYesTheVolumeIsEntered() {
        defer { detach() }
        guard attached else {
            return
        }
        let fileSystems = makeFileSystems().0
        let replies = Review2Replies()
        replies.volume = .proceed
        let job = FileJob(
            kind: .delete(toTrash: false),
            sources: [box.url("tree")],
            target: nil,
            fileSystems: fileSystems
        )
        job.delegate = replies
        _ = job.run()
        #expect(
            replies.volumes == ["mnt"]
                && !FileManager.default.fileExists(atPath: mount.appendingPathComponent("precious.txt").path)
        )
    }
}
