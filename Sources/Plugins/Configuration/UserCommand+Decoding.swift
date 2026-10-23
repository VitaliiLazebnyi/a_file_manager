/// Stored user commands are read leniently.
///
/// A missing key other than the name takes its default and an unknown one is ignored, so a field
/// added or removed by another version never makes the whole list unreadable.
extension UserCommand {
    private enum Keys: String, CodingKey {
        case action = "action"
        case name = "name"
        case symbol = "symbol"
        case title = "title"
    }

    /// Reads a user command; only its name must be there.
    ///
    /// Throws when the name is missing or a field has the wrong type.
    internal init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        action = try container.decodeIfPresent(CommandAction.self, forKey: .action) ?? CommandAction()
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? ""
    }
}
