import Foundation
import TestSupport

/// A small HFS+ disk image attached to a folder: a volume that cannot clone files.
///
/// Detached when it goes; nil where no image can be attached.
internal final class CoverageArchivesDiskImage {
    /// Where the volume is mounted.
    internal let mountPoint: URL

    /// Makes and attaches the image beside `name` in `box`.
    internal init?(in box: Sandbox, at name: String) {
        let image = box.url("\(name).dmg")
        mountPoint = box.url(name)
        guard (try? box.folder(name)) != nil,
            Self.run(["create", "-size", "4m", "-fs", "HFS+", "-volname", "AFMCoverage", image.path]),
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
