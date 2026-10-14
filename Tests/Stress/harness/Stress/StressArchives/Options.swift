import Foundation

/// The command line of the harness: `--key value` pairs, a key without a value counts as "1".
internal struct Options: Sendable {
    /// The folder with `big.zip`, `deep.zip` and the probes (`--dir`, the current folder at first).
    internal let directory: URL
    /// `big` or `deep` (`--mode`).
    internal let mode: String
    /// How long the concurrent stage runs, in seconds (`--seconds`).
    internal let duration: Double
    /// How many threads read members at once (`--readers`).
    internal let readerCount: Int
    /// How many members the big archive has besides the probes (`--entries`).
    internal let expectedEntries: Int
    /// How deep the chain of folders of the deep archive goes (`--chain`).
    internal let chainDepth: Int
    /// Where samples and the leaks report go (`--results`).
    internal let results: String
    /// The seed of every random choice (`--seed`).
    internal let seed: UInt64
    /// Whether `leaks(1)` is run on the process at the end (`--leaks`).
    internal let runsLeaks: Bool

    /// Reads the options from `commandLine` (the program's name first).
    internal init(commandLine: [String]) {
        var values: [String: String] = [:]
        var rest = Array(commandLine.dropFirst())
        while !rest.isEmpty {
            let key = rest.removeFirst()
            values[key] = rest.isEmpty || rest[0].hasPrefix("--") ? "1" : rest.removeFirst()
        }

        func number(_ name: String, _ fallback: Int) -> Int {
            values[name].flatMap(Int.init) ?? fallback
        }

        let current = FileManager.default.currentDirectoryPath
        directory = URL(fileURLWithPath: values["--dir"] ?? current)
        mode = values["--mode"] ?? "big"
        duration = Double(number("--seconds", 60))
        readerCount = number("--readers", 16)
        expectedEntries = number("--entries", 200_000)
        chainDepth = number("--chain", 2_000)
        results = values["--results"] ?? current
        seed = UInt64(number("--seed", 1))
        runsLeaks = values["--leaks"] != nil
    }
}
