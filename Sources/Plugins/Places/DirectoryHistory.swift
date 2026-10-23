import AFMKernel
public import Foundation

/// The directories one panel visited, oldest first (spec 03 › Directory history list).
///
/// The panel's own back/forward list forgets what lay ahead; this one keeps every place once.
public struct DirectoryHistory: Codable, Equatable {
    /// The stored field names.
    private enum Keys: String, CodingKey {
        case visits = "visits"
    }

    /// What is kept per panel (`HistoryLenStored`).
    public static let storedLimit = 200

    /// The visits, oldest first; a directory is in it once.
    public private(set) var visits: [DirectoryVisit] = []

    /// The directory the panel is in, as far as the history knows.
    public var current: URL? { visits.last.flatMap { URL(string: $0.location) } }

    /// An empty history.
    public init() {
        // Nothing visited: `visits` starts empty.
    }

    /// Reads a stored history leniently (see `StoredSettings`): a visit that cannot be read is left out, and of too
    /// many only the last `storedLimit` are kept.
    ///
    /// Throws when the visits are not stored as a list.
    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: Keys.self)
        let stored = try container.decodeIfPresent(LenientElements<DirectoryVisit>.self, forKey: .visits)
        visits = Array((stored?.elements ?? []).suffix(Self.storedLimit))
    }

    /// The location as it is stored: a password in a URL is left out, because histories land
    /// in the settings, which are exported and shared.
    internal static func stored(_ directory: URL) -> String {
        let text = directory.absoluteString
        // The range is one in the components' own text.
        guard text.contains("@"), let components = URLComponents(string: text), var stored = components.string,
            let password = components.rangeOfPassword
        else { return text }
        // The password goes with the colon that leads it in.
        stored.removeSubrange(stored.index(before: password.lowerBound)..<password.upperBound)
        return stored
    }

    /// The panel shows `directory` now.
    ///
    /// `stayedInPrevious` says whether the directory it left was more than passed through; that one
    /// then stays visible under thinning. A directory that was visited before moves to the end.
    /// Returns false when nothing changed.
    @discardableResult
    public mutating func record(_ directory: URL, stayedInPrevious: Bool) -> Bool {
        let key = directory.locationKey
        if let last = visits.last, last.key == key {
            return false
        }
        if stayedInPrevious, !visits.isEmpty {
            visits[visits.count - 1].isVisible = true
        }
        let earlier = visits.firstIndex { $0.key == key }
        let wasVisible = earlier.map { visits.remove(at: $0).isVisible } ?? false
        visits.append(DirectoryVisit(location: Self.stored(directory), isVisible: wasVisible))
        if visits.count > Self.storedLimit {
            visits.removeFirst(visits.count - Self.storedLimit)
        }
        return true
    }

    /// Shift+Del in the list: forgets a directory.
    public mutating func remove(_ directory: URL) {
        let key = directory.locationKey
        visits.removeAll { $0.key == key }
    }

    /// The list as it is shown: the last visited first.
    ///
    /// With `thinning`, folders that were only passed through are left out; the current directory
    /// is always there.
    public func shown(thinning: Bool, limit: Int? = nil) -> [URL] {
        let last = visits.count - 1
        let urls =
            visits
            .enumerated()
            .reversed()
            .compactMap { index, visit in
                !thinning || visit.isVisible || index == last ? URL(string: visit.location) : nil
            }
        return limit.map { Array(urls.prefix(max($0, 1))) } ?? urls
    }
}
