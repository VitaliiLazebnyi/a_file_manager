import AFMKernel
import Foundation
import FuzzCore

@testable import NetworkPlugin

/// The `saved` target: the saved connections, the history and the trusted certificates as the
/// settings store hands them out.
internal enum SavedFuzz {
    /// Tokens of the stored JSON.
    private static let dict = [
        "\"id\"", "\"name\"", "\"kind\"", "\"host\"", "\"port\"", "\"user\"", "\"anonymous\"", "\"remoteDirectory\"",
        "\"localDirectory\"", "\"passive\"", "\"encoding\"", "\"listing\"", "\"initCommands\"", "null", "true", "-1",
        "99", "1e99", "9223372036854775808", "[", "]", "{", "}", ",", ":", "\"\"", "\\u0000", "\\ud800"
    ]

    /// The target.
    ///
    /// - Returns: The target for `fuzzMain`.
    internal static func target() -> FuzzTarget {
        FuzzTarget("saved", maxLen: 4_096, dict: dict, seeds: seeds, run: run)
    }

    /// Two saved connections as the app stores them, and empty lists.
    ///
    /// - Returns: The seeds.
    private static func seeds() -> [[UInt8]] {
        var work = SavedConnection()
        work.name = "Work"
        work.host = "ftp.example.com"
        work.port = 2_121
        work.user = "me"
        work.remoteDirectory = "pub/../x"
        work.initCommands = "SITE A;;B;C"
        var other = SavedConnection()
        if let lastKind = SavedConnection.Kind.allCases.last {
            other.kind = lastKind
        }
        other.host = "::1"
        other.encoding = .shiftJIS
        other.listing = .mlsd
        let json = (try? JSONEncoder().encode([work, other])) ?? Data()
        return [[UInt8](json), Array("[]".utf8), Array("[{}]".utf8)]
    }

    /// Stores what the input decodes to and reads it back through a connection store.
    ///
    /// - Parameter bytes: The input.
    @MainActor
    private static func run(_ bytes: [UInt8]) {
        let data = Data(bytes)
        // As the settings store hands it out: the stored value decoded into the model.
        let settings = MemorySettings()
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let list = try? JSONDecoder().decode([SavedConnection].self, from: data) {
                settings.set(list, forKey: "network.connections")
                list.forEach(NetFuzz.exercise)
            }
            if let texts = object as? [String] {
                settings.set(texts, forKey: "network.history")
            }
            if let trusted = object as? [String: [String]] {
                settings.set(trusted, forKey: "network.trustedCertificates")
            }
        }
        if let one = try? JSONDecoder().decode(SavedConnection.self, from: data) {
            NetFuzz.exercise(one)
        }
        let store = ConnectionStore(settings: settings, passwords: MemoryPasswords())
        for connection in store.connections {
            NetFuzz.exercise(connection)
            store.save(connection)
            _ = store.connection(named: connection.name)
        }
        for typed in store.history {
            if let address = ServerAddress(typed) {
                store.remember(address: address)
            }
        }
        _ = store.lastUsed
        _ = store.trustedCertificates
    }
}
