import AFMKernel
import Foundation

/// Reading stored values without losing them: when what is stored cannot be read in full, a
/// copy is kept under `<key>.unreadable` before anything else is saved over it.
internal enum StoredSettings {
    /// The value under `key`; nil when nothing is stored or none of it can be read.
    ///
    /// `problem` is called with a message when the data was damaged or partly left out.
    internal static func load<Value: Decodable>(
        _ type: Value.Type,
        key: String,
        in settings: any SettingsStore,
        problem: (String) -> Void
    ) -> Value? {
        guard let data = settings.data(forKey: key) else {
            return nil
        }
        let report = DecodeReport()
        let value = DecodeReport.$current.withValue(report) {
            try? JSONDecoder().decode(type, from: data)
        }
        guard value == nil || report.skipped > 0 else {
            return value
        }
        let backup = key + ".unreadable"
        if settings.data(forKey: backup) == nil {
            settings.set(data as Data?, forKey: backup)
        }
        problem(
            value == nil
                ? "The stored data of “\(key)” could not be read."
                : "\(report.skipped) stored entries of “\(key)” could not be read and were left out."
        )
        return value
    }
}

/// Reading a stored entry leniently.
///
/// A missing key takes its default and an unknown key is ignored, so a field another version added or removed never
/// makes the list unreadable.
extension HotlistEntry {
    /// The stored field names.
    private enum Keys: String, CodingKey {
        case kind = "kind"
        case title = "title"
        case command = "command"
        case target = "target"
        case children = "children"
    }

    /// Reads a stored entry; a missing field takes its default, a submenu keeps the children it can read.
    ///
    /// Throws only when the stored value is not an object or a field holds the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .item
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        children = try container.decodeIfPresent(LenientElements<HotlistEntry>.self, forKey: .children)?.elements ?? []
    }
}

/// Reading a stored hotlist leniently, as `HotlistEntry` does.
extension Hotlist {
    /// The stored field names.
    private enum Keys: String, CodingKey {
        case entries = "entries"
        case hideCharacter = "hideCharacter"
        case hidesMarked = "hidesMarked"
    }

    /// Reads a stored hotlist, keeping the entries it can read and at most `limit` of them.
    ///
    /// What is left out or cut off is counted in the running `DecodeReport`. Throws only when the stored value is
    /// not an object or a field holds the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        entries = try container.decodeIfPresent(LenientElements<HotlistEntry>.self, forKey: .entries)?.elements ?? []
        hideCharacter = try container.decodeIfPresent(String.self, forKey: .hideCharacter) ?? "?"
        hidesMarked = try container.decodeIfPresent(Bool.self, forKey: .hidesMarked) ?? false
        // The limit holds for what is stored as well as for what is added (a file that was
        // edited by hand or imported); what is cut off is counted, so the user is told.
        var room = Self.limit
        let cut = Self.trimmed(&entries, room: &room)
        DecodeReport.current?.skipped += cut
    }
}
