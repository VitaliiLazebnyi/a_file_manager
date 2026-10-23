import Foundation

/// Watches the room on a volume while something large is written to it: asked for every
/// block, it looks at the volume once per `step` bytes.
///
/// Used by one thread.
internal final class SpaceWatch {
    private let folder: URL
    private let reserve: UInt64
    private let hasRoom: (UInt64, URL) -> Bool
    private let step: UInt64
    private var sinceCheck: UInt64
    private var full = false

    /// Watches the volume of `folder`, asking `hasRoom` whether it has room for a number of bytes.
    ///
    /// `reserve` bytes stay free whatever is written.
    internal init(folder: URL, reserve: UInt64, step: UInt64, hasRoom: @escaping (UInt64, URL) -> Bool) {
        self.folder = folder
        self.reserve = reserve
        self.hasRoom = hasRoom
        self.step = step
        sinceCheck = 0
    }

    /// False once writing `count` more bytes would eat into the reserve.
    internal func allows(_ count: UInt64) -> Bool {
        guard !full else {
            return false
        }
        sinceCheck = sinceCheck.plusClamped(count)
        guard sinceCheck >= step else {
            return true
        }
        sinceCheck = 0
        full = !hasRoom(reserve.plusClamped(step), folder)
        return !full
    }

    deinit {
        // Nothing to release.
    }
}
