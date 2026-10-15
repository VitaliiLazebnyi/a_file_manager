/// One setting the user can change in the configuration dialog (spec 13 › The dialog framework).
///
/// The value lives in the settings store under `key`.
public struct Preference: Sendable {
    /// What the setting holds, with the value it has until the user changes it.
    public enum Kind: Sendable {
        /// On or off.
        case flag(default: Bool)
        /// A line of text.
        case text(default: String)
        /// One of a few options; the index is stored.
        case choice([String], default: Int)
    }

    /// The full settings key, e.g. `viewer.wrapLines`.
    public let key: String
    /// What the dialog calls the setting.
    public let label: String
    /// What the setting holds.
    public let kind: Kind

    /// A setting shown as `label`, stored under `key`.
    public init(_ key: String, _ label: String, _ kind: Kind) {
        (self.key, self.label, self.kind) = (key, label, kind)
    }
}
