/// Stored actions are read leniently.
///
/// A missing key takes its default and an unknown one is ignored, so a field added or removed by
/// another version never makes the whole list unreadable.
extension CommandAction {
    private enum Keys: String, CodingKey {
        case command = "command"
        case parameters = "parameters"
        case startPath = "startPath"
    }

    /// Reads an action, with an empty field for every key that is missing.
    ///
    /// Throws when the stored value is not a keyed container or a field is not text.
    internal init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        parameters = try container.decodeIfPresent(String.self, forKey: .parameters) ?? ""
        startPath = try container.decodeIfPresent(String.self, forKey: .startPath) ?? ""
    }
}
