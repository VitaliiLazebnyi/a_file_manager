public import Foundation

/// How volumes are looked at and ejected.
///
/// Both calls ask the volume and may wait on it: they run on a job's thread. Tests put a stand-in
/// in place of the system.
public protocol VolumeAccess: AnyObject, Sendable {
    /// What is known of the volume `directory` is on; facts with no volume when it cannot be told.
    func facts(of directory: URL) -> VolumeFacts
    /// Ejects gently: the system writes what is pending and refuses while any program has a
    /// file of the volume open. Nil when the volume is gone.
    func eject(_ volume: VolumeFacts) -> EjectRefusal?
}
