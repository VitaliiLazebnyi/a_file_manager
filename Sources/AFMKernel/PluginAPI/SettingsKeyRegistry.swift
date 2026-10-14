/// The settings keys the plugins have declared.
///
/// Filled while the plugins start; main thread.
@preconcurrency
@MainActor
public final class SettingsKeyRegistry {
    /// What a plugin said about one key or one family of keys.
    public struct Declaration: Sendable {
        /// The key, or for a family of keys what they all begin with.
        public let key: String
        /// True for a family of keys (`key` is what they begin with).
        public let isPrefix: Bool
        /// What the key holds.
        public let kind: SettingsKeyKind
    }

    private var exact: [String: Declaration] = [:]
    private var families: [Declaration] = []

    /// Everything declared, single keys first.
    public var all: [Declaration] { exact.values.sorted { $0.key < $1.key } + families }

    /// An empty registry; the kernel makes the one the plugins fill.
    public init() {
        // Keys are declared by the plugins.
    }

    /// Says what a key of the plugin's is.
    ///
    /// Declaring a key twice keeps the later word.
    public func declare(_ key: String, kind: SettingsKeyKind = .ordinary) {
        exact[key] = Declaration(key: key, isPrefix: false, kind: kind)
    }

    /// The same for every key that begins with `prefix` (`findFiles.history.`).
    public func declare(prefix: String, kind: SettingsKeyKind = .ordinary) {
        families.removeAll { $0.key == prefix }
        families.append(Declaration(key: prefix, isPrefix: true, kind: kind))
    }

    deinit {
        // Nothing to release.
    }
}
