/// Stored Start-menu entries are read leniently.
///
/// A missing action is an empty one and an unknown key is ignored, so a field added or removed by
/// another version never makes the whole menu unreadable.
extension StartMenuEntry {
    private enum Keys: String, CodingKey {
        case action = "action"
        case title = "title"
    }

    /// Reads an entry; only its title must be there.
    ///
    /// Throws when the title is missing or a field has the wrong type.
    internal init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        title = try container.decode(String.self, forKey: .title)
        action = try container.decodeIfPresent(CommandAction.self, forKey: .action) ?? CommandAction()
    }
}
