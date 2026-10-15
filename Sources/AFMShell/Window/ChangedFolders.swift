import AFMKernel
import Foundation

/// The folders a change made by another program concerns.
internal enum ChangedFolders: Equatable {
    /// Any folder: everything the panels show is looked at again.
    case all
    /// These folders.
    case only([URL])

    /// Whether a panel that shows `directory` is concerned.
    internal func concerns(_ directory: URL) -> Bool {
        switch self {
        case .all:
            return true

        case .only(let folders):
            return folders.contains { $0.isSameLocation(as: directory) }
        }
    }
}
