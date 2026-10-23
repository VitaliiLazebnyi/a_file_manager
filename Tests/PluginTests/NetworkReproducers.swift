import Foundation

/// The inputs the fuzzing run found trouble with, kept under `Tests/Fuzz/repro/net`.
internal enum NetworkReproducers {
    /// The bytes of the reproducer `name`; throws when it cannot be read.
    internal static func data(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: tests.appendingPathComponent("Fuzz/repro/net/" + name))
    }

    /// The reproducer `name` as UTF-8 text; throws when it cannot be read or is no UTF-8.
    internal static func text(_ name: String) throws -> String {
        guard let text = String(bytes: try data(name), encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}
