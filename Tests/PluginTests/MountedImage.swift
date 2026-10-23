import Foundation
import TestSupport

/// A disk image attached to a folder, so that a real mount point exists; detached when it goes.
internal final class MountedImage {
    /// The folder the image is attached to.
    internal let mountPoint: URL
    private let image: URL

    /// Makes a small image in `box` and attaches it to the new folder `name`; nil where that is
    /// not possible (no `hdiutil`, or no right to attach).
    internal init?(in box: Sandbox, at name: String) {
        image = box.url("\(name).dmg")
        mountPoint = box.url(name)
        guard (try? box.folder(name)) != nil,
            Self.run(["create", "-size", "4m", "-fs", "HFS+", "-volname", "AFMTest", image.path]),
            Self.run(["attach", image.path, "-nobrowse", "-mountpoint", mountPoint.path])
        else {
            return nil
        }
    }

    private static func run(_ arguments: [String]) -> Bool {
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

    deinit {
        _ = Self.run(["detach", "-force", mountPoint.path])
    }
}
