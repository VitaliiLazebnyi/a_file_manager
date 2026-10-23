import AFMKernel
import Foundation
import SystemToolsPlugin

/// A drive that is a folder of the sandbox: what it answers and how its ejects go is up to the test.
///
/// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
internal final class StandInDrive: VolumeAccess, @unchecked Sendable {
    /// The folder that stands for the drive.
    internal let volume: URL
    private let lock = NSLock()
    private var refusals: [EjectRefusal?]
    private var ejectCount = 0

    /// How often the drive was asked to eject.
    internal var ejects: Int {
        lock.lock()
        defer { lock.unlock() }
        return ejectCount
    }

    /// A drive at `volume` whose ejects are answered by `refusals` in turn, then all succeed.
    internal init(_ volume: URL, refusals: [EjectRefusal?]) {
        self.volume = volume
        self.refusals = refusals
    }

    /// The drive for a folder inside it (one that can be ejected), the start-up disk for any other.
    internal func facts(of directory: URL) -> VolumeFacts {
        guard directory.isSameLocation(as: volume) || directory.isInside(volume) else {
            return VolumeFacts(url: URL(fileURLWithPath: "/"), name: "Macintosh HD")
        }
        return VolumeFacts(url: volume, name: "STICK", canBeEjected: true)
    }

    /// Counts the eject and answers with the next refusal, if one is left.
    internal func eject(_: VolumeFacts) -> EjectRefusal? {
        lock.lock()
        defer { lock.unlock() }
        ejectCount += 1
        return refusals.isEmpty ? nil : refusals.removeFirst()
    }

    deinit {
        // Nothing to release.
    }
}
