import Dispatch

/// The local file system's own clock: what has to happen "a moment later" whatever else the
/// program is doing (the second signal to a call that is to be ended, giving up on a
/// question nobody answers).
///
/// Not the system's shared queues: when all their threads are taken by work that waits, nothing put
/// on them runs, and these are the steps that free such threads. Nothing on this queue ever waits
/// for anything.
internal enum LocalClock {
    /// The serial queue the delayed steps are put on.
    internal static let queue = DispatchQueue(label: "AFM.LocalFileSystem.clock", qos: .userInitiated)
}
