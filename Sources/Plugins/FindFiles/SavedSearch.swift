/// A search kept under a name in the Load/Save tab (spec 09 › Load/Save tab).
public struct SavedSearch: Codable, Equatable, Sendable {
    /// The name it is listed and loaded by; names differ in more than case.
    public var name: String
    /// What the window held when the search was saved.
    public var settings: SearchSettings

    /// The search `settings` under `name`.
    public init(name: String, settings: SearchSettings) {
        self.name = name
        self.settings = settings
    }
}
