import Foundation
import os

/// The settings keys the plugins have declared. Filled while the plugins start; main thread.
@MainActor
public final class SettingsKeyRegistry {
    public struct Declaration: Sendable {
        /// The key, or for a family of keys what they all begin with.
        public let key: String
        public let isPrefix: Bool
        public let kind: SettingsKeyKind
    }

    private var exact: [String: Declaration] = [:]
    private var families: [Declaration] = []

    public init() {}

    /// Says what a key of the plugin's is. Declaring a key twice keeps the later word.
    public func declare(_ key: String, kind: SettingsKeyKind = .ordinary) {
        exact[key] = Declaration(key: key, isPrefix: false, kind: kind)
    }

    /// The same for every key that begins with `prefix` (`findFiles.history.`).
    public func declare(prefix: String, kind: SettingsKeyKind = .ordinary) {
        families.removeAll { $0.key == prefix }
        families.append(Declaration(key: prefix, isPrefix: true, kind: kind))
    }

    /// Everything declared, single keys first.
    public var all: [Declaration] { exact.values.sorted { $0.key < $1.key } + families }
}
