import Foundation

/// What the command line asked for, with the defaults of a full run.
internal struct Settings: Sendable {
    /// Every `--name value` pair of the command line; a name without a value reads "1".
    internal let arguments: [String: String]
    /// Where the trees are made (`--root`).
    internal let root: URL
    /// How many small files the local tree has (`--files`).
    internal let fileCount: Int
    /// How many folders the small files are spread over (`--folders`).
    internal let folderCount: Int
    /// How many files larger than `FileJob.smallFileLimit` the local tree has (`--big`).
    internal let bigCount: Int
    /// How many seeds run on the local tree (`--seeds`).
    internal let seedCount: Int
    /// The first seed (`--seedbase`).
    internal let seedBase: Int
    /// How many seeds run against the target that keeps writes back (`--memseeds`).
    internal let memSeeds: Int
    /// Leaves out the runs on the local tree (`--skiplocal`).
    internal let skipLocal: Bool
    /// Leaves the trees in place at the end (`--keep`).
    internal let keepTree: Bool
    /// Where samples of a hanging process go (`--results`).
    internal let results: String

    /// The settings of `commandLine` (the program's name first).
    internal init(commandLine: [String]) {
        var parsed: [String: String] = [:]
        var rest = Array(commandLine.dropFirst())
        while !rest.isEmpty {
            let key = rest.removeFirst()
            parsed[key] = (rest.first?.hasPrefix("--") ?? true) ? "1" : rest.removeFirst()
        }
        arguments = parsed
        let fallbackRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("afm-stress/jobs")
        root = URL(fileURLWithPath: parsed["--root"] ?? fallbackRoot.path)
        fileCount = parsed["--files"].flatMap(Int.init) ?? 100_000
        folderCount = parsed["--folders"].flatMap(Int.init) ?? 2_000
        bigCount = parsed["--big"].flatMap(Int.init) ?? 12
        seedCount = parsed["--seeds"].flatMap(Int.init) ?? 50
        seedBase = parsed["--seedbase"].flatMap(Int.init) ?? 1
        memSeeds = parsed["--memseeds"].flatMap(Int.init) ?? 0
        skipLocal = parsed["--skiplocal"] != nil
        keepTree = parsed["--keep"] != nil
        results = parsed["--results"] ?? FileManager.default.currentDirectoryPath
    }

    /// The number given as `name`, or `fallback`.
    internal func number(_ name: String, _ fallback: Int) -> Int {
        arguments[name].flatMap(Int.init) ?? fallback
    }
}
