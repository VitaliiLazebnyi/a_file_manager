import AFMKernel
public import Foundation

/// How often each directory was visited, in either panel (spec 03 › Directory history list,
/// "frequently used folders").
public struct FrequentFolders: Codable, Equatable {
    /// The stored field names.
    private enum Keys: String, CodingKey {
        case counts = "counts"
    }

    /// What is kept (`FrequentlyUsedLenStored`).
    public static let storedLimit = 200

    /// The number of visits per stored location (as `DirectoryHistory.stored` writes it).
    public private(set) var counts: [String: Int] = [:]

    /// No folder counted yet.
    public init() {
        // Nothing counted: `counts` starts empty.
    }

    /// Reads stored counts leniently (see `StoredSettings`): a negative count becomes 0, and of too many only the most
    /// visited `storedLimit` are kept.
    ///
    /// Throws when the counts are stored with the wrong type.
    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: Keys.self)
        let stored = try container.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        // No negative count, and no more than are kept: the most visited stay.
        let kept =
            stored.count > Self.storedLimit
            ? Array(stored.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(Self.storedLimit))
            : Array(stored)
        counts = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, max($0.value, 0)) })
    }

    /// Counts one more visit of `directory`; when more than `storedLimit` folders are counted, the least visited other
    /// one is forgotten.
    public mutating func record(_ directory: URL) {
        let own = DirectoryHistory.stored(directory)
        // A stored count can be anything (settings are imported): it stops at the top.
        let before = counts[own] ?? 0
        counts[own] = before == Int.max ? before : before + 1
        guard counts.count > Self.storedLimit else {
            return
        }
        // The least visited folder makes room; the one just counted stays.
        if let rarest = counts.filter({ $0.key != own }).min(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            counts[rarest.key] = nil
        }
    }

    /// Shift+Del in the list: forgets the count of `directory`, whichever way its location was written.
    public mutating func remove(_ directory: URL) {
        let key = directory.locationKey
        counts = counts.filter { URL(string: $0.key)?.locationKey != key }
    }

    /// The most visited folders, the most frequent first.
    public func top(_ limit: Int? = nil) -> [(directory: URL, visits: Int)] {
        let ranked = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .compactMap { entry in
                URL(string: entry.key).map { (directory: $0, visits: entry.value) }
            }
        return limit.map { Array(ranked.prefix(max($0, 0))) } ?? ranked
    }
}
