import AFMKernel
import Foundation

/// Counts what a lenient decode had to leave out, so whoever loads can tell the user.
final class DecodeReport {
    static let key = CodingUserInfoKey(rawValue: "afm.places.decodeReport")!
    var skipped = 0
}

/// An array read element by element: an element that cannot be decoded is counted in the
/// decoder's `DecodeReport` and skipped, the rest is kept.
struct LenientElements<Element: Decodable>: Decodable {
    private struct Ignored: Decodable { init(from _: Decoder) {} }

    var elements: [Element] = []

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let report = decoder.userInfo[DecodeReport.key] as? DecodeReport
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                report?.skipped += 1
                _ = try container.decode(Ignored.self)
            }
        }
    }
}

/// Reading stored values without losing them: when what is stored cannot be read in full, a
/// copy is kept under `<key>.unreadable` before anything else is saved over it.
enum StoredSettings {
    /// The value under `key`; nil when nothing is stored or none of it can be read.
    /// `problem` is called with a message when the data was damaged or partly left out.
    static func load<Value: Decodable>(
        _ type: Value.Type, key: String, in settings: SettingsStore, problem: (String) -> Void
    ) -> Value? {
        guard let data = settings.data(forKey: key) else { return nil }
        let report = DecodeReport()
        let decoder = JSONDecoder()
        decoder.userInfo[DecodeReport.key] = report
        let value = try? decoder.decode(type, from: data)
        guard value == nil || report.skipped > 0 else { return value }
        let backup = key + ".unreadable"
        if settings.data(forKey: backup) == nil { settings.set(data as Data?, forKey: backup) }
        problem(
            value == nil
                ? "The stored data of “\(key)” could not be read."
                : "\(report.skipped) stored entries of “\(key)” could not be read and were left out.")
        return value
    }
}

// Stored data is read leniently: a missing key takes its default and an unknown key is ignored,
// so a field another version added or removed never makes the list unreadable.
extension HotlistEntry {
    private enum Keys: String, CodingKey { case kind, title, command, target, children }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .item
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        children = try container.decodeIfPresent(LenientElements<HotlistEntry>.self, forKey: .children)?.elements ?? []
    }
}

extension Hotlist {
    private enum Keys: String, CodingKey { case entries, hideCharacter, hidesMarked }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        entries = try container.decodeIfPresent(LenientElements<HotlistEntry>.self, forKey: .entries)?.elements ?? []
        hideCharacter = try container.decodeIfPresent(String.self, forKey: .hideCharacter) ?? "?"
        hidesMarked = try container.decodeIfPresent(Bool.self, forKey: .hidesMarked) ?? false
        // The limit holds for what is stored as well as for what is added (a file that was
        // edited by hand or imported); what is cut off is counted, so the user is told.
        var room = Self.limit
        let cut = Self.trimmed(&entries, room: &room)
        (decoder.userInfo[DecodeReport.key] as? DecodeReport)?.skipped += cut
    }
}
