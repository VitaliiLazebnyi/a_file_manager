import AFMKernel
import Foundation

/// Changes reported while a job was running, to be read when it has ended.
///
/// Each folder is noted once however often it is reported; beyond a handful of folders
/// everything is simply looked at again.
internal struct MissedChanges {
    /// How many folders are noted one by one.
    internal static let limit = 64

    /// The folders reported, by location.
    private var folders: [String: URL] = [:]
    /// Whether everything has to be looked at again.
    private var concernsAll = false
    /// Whether anything was reported since the last `take`.
    private var isNoted = false
    /// When the last change was reported, in the system's uptime.
    private var last: TimeInterval = 0

    /// Notes a change of `changed`, reported at `time`.
    internal mutating func note(_ changed: ChangedFolders, at time: TimeInterval) {
        switch changed {
        case .only(let directories) where !concernsAll:
            for directory in directories {
                folders[directory.locationKey] = directory
            }
            if folders.count > Self.limit {
                (concernsAll, folders) = (true, [:])
            }

        case .all, .only:
            (concernsAll, folders) = (true, [:])
        }
        isNoted = true
        last = time
    }

    /// What was noted, and when the last of it was reported; nil when nothing was.
    ///
    /// Forgets it.
    internal mutating func take() -> (changed: ChangedFolders, at: TimeInterval)? {
        guard isNoted else {
            return nil
        }
        let taken = (concernsAll ? ChangedFolders.all : .only(Array(folders.values)), last)
        self = Self()
        return taken
    }
}
