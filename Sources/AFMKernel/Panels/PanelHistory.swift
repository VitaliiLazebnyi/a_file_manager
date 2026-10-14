import Foundation

/// The directories a panel has shown, in the order they were visited, and where in that list
/// the panel is now (spec 03 › Navigation).
internal struct PanelHistory: Sendable {
    /// The visited directories, oldest first.
    internal private(set) var locations: [URL]
    /// The place of the directory shown now.
    internal private(set) var index = 0

    /// The directory before the current one; nil at the start.
    internal var back: URL? { index > 0 ? locations[index - 1] : nil }
    /// The directory after the current one; nil at the end.
    internal var forward: URL? { index < locations.count - 1 ? locations[index + 1] : nil }

    /// A history that holds only the first directory.
    internal init(_ first: URL) {
        locations = [first]
    }

    /// The most recent directory before the current one that `isWanted` accepts.
    internal func lastVisited(where isWanted: (URL) -> Bool) -> URL? {
        locations[..<min(index, locations.count)].last(where: isWanted)
    }

    /// What a new listing of `directory` does to the history.
    internal mutating func record(_ directory: URL, _ effect: PanelModel.HistoryEffect) {
        switch effect {
        case .record:
            guard !locations[index].isSameLocation(as: directory) else {
                return
            }
            locations.removeSubrange((index + 1)...)
            locations.append(directory)
            if locations.count > PanelModel.historyLimit { locations.removeFirst() }
            index = locations.count - 1

        case .step(let delta):
            index = max(0, min(index + delta, locations.count - 1))

        case .keep:
            break
        }
    }

    /// The directory that was entered before it was read turned out to be another one (the
    /// location of a file leads to its folder): the visit is the same, its place is corrected.
    internal mutating func replaceCurrent(with directory: URL) {
        locations[index] = directory
    }
}
