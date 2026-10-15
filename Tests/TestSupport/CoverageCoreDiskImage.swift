public import Foundation

/// A disk image attached to a folder of a sandbox: a volume of its own, for what only happens between two volumes
/// (a copy that cannot be a clone, a move that is a copy) or on a volume that goes away.
///
/// Unchecked: its state changes only in `detach`, which a test calls from one thread.
public final class CoverageCoreDiskImage: @unchecked Sendable {
    /// Detaches, once per test process, the images of test processes that ended without detaching theirs (killed,
    /// stopped in a debugger): an image of a sandbox whose owner file names a process that no longer runs.
    private static let leftoversDetached: Void = {
        let info = Process()
        let output = Pipe()
        info.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        info.arguments = ["info", "-plist"]
        info.standardOutput = output
        info.standardError = FileHandle.nullDevice
        guard (try? info.run()) != nil else {
            return
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        info.waitUntilExit()
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        for attached in plist?["images"] as? [[String: Any]] ?? [] {
            guard let path = attached["image-path"] as? String, path.contains("/afm-tests-") else {
                continue
            }
            let owner = (try? String(contentsOf: ownerFile(of: URL(fileURLWithPath: path)), encoding: .utf8))
                .flatMap { pid_t($0) }
            // A process that runs answers signal 0 (or is not ours to signal); a gone one answers ESRCH.
            guard owner.map({ kill($0, 0) != 0 && errno == ESRCH }) ?? true else {
                continue
            }
            let entities = attached["system-entities"] as? [[String: Any]] ?? []
            for point in entities.compactMap({ $0["mount-point"] as? String }) {
                _ = run(["detach", "-force", point])
            }
        }
    }()

    /// Where the volume is mounted: the folder `<name>-mount` of the sandbox.
    public let mountPoint: URL
    /// The mount point as the system lists its volumes: with links resolved (`/private/var/…`).
    public var systemPath: String {
        guard let resolved = realpath(mountPoint.path, nil) else {
            return mountPoint.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private let image: URL
    private var isAttached = true

    /// Makes and attaches an image; nil where `hdiutil` cannot do that.
    ///
    /// The image holds `megabytes`, with a volume of `fileSystem` (as `hdiutil` names it) called `name`. A
    /// `browsable` volume is listed among the volumes as a plugged-in disk
    /// would be.
    public init?(
        in box: Sandbox,
        name: String,
        megabytes: Int = 8,
        fileSystem: String = "HFS+",
        browsable: Bool = false
    ) {
        image = box.url("\(name).dmg")
        // A folder name that is not the volume's, so that the two can be told apart.
        mountPoint = box.url("\(name)-mount")
        let attach = ["attach", image.path, "-mountpoint", mountPoint.path] + (browsable ? [] : ["-nobrowse"])
        _ = Self.leftoversDetached
        // The image service is busy now and then when several images come and go at once: tried a few times.
        guard (try? box.folder("\(name)-mount")) != nil,
            Self.run(["create", "-ov", "-size", "\(megabytes)m", "-fs", fileSystem, "-volname", name, image.path]),
            (try? "\(getpid())".write(to: Self.ownerFile(of: image), atomically: true, encoding: .utf8)) != nil,
            Self.run(attach)
        else { return nil }
    }

    /// The file next to an image that names the process that attached it.
    private static func ownerFile(of image: URL) -> URL {
        image.appendingPathExtension("owner")
    }

    private static func run(_ arguments: [String]) -> Bool {
        (0..<3).contains { _ in runOnce(arguments) }
    }

    private static func runOnce(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments + ["-quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Takes the volume away at once, whatever is open on it: what is open fails from then on.
    public func detach() {
        guard isAttached else {
            return
        }
        isAttached = false
        _ = Self.run(["detach", "-force", mountPoint.path])
    }

    deinit { detach() }
}
