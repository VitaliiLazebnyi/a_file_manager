internal import Foundation

/// `fuzz`: starts workers one after the other until the time or the input count is used up.
///
/// When a worker dies, the input it was running is filed under `out/findings/<signature>/` (the three smallest of each
/// signature are kept) and is not run again.
@MainActor
internal final class FuzzSupervisor {
    /// The target fuzzed.
    private let target: FuzzTarget
    /// The command-line options.
    private let options: FuzzOptions
    /// The output folder.
    private let out: String
    /// The work folder of the running worker: below the system's temporary folder, gone when the run ends.
    private let work: String
    /// When the run started.
    private let started = Date()
    /// Inputs run by all workers.
    private var totalExecs = 0
    /// Workers started after the first.
    private var restarts = 0
    /// Edges seen, as the last worker reported them.
    private var edges = "0"
    /// Milliseconds of the slowest input.
    private var slowest = 0.0
    /// Milliseconds per KiB of the slowest input of at least 512 bytes.
    private var slowestPerKB = 0.0
    /// The target's last note.
    private var note = ""
    /// How often each signature was found.
    private var counts: [String: Int] = [:]

    /// A supervisor for `target` with the given options.
    internal init(target: FuzzTarget, options: FuzzOptions) {
        self.target = target
        self.options = options
        out = options.out
        work = FuzzFiles.workBase() + "/work-\(target.name)-\(getpid())"
    }

    /// Fuzzes, prints what was found and exits 0.
    internal func run() -> Never {
        guard !out.isEmpty else {
            print("--out is required")
            exit(2)
        }
        FuzzFiles.makeFolder(out + "/findings")
        while true {
            let arguments = nextWorkerArguments()
            if arguments.isEmpty {
                break
            }
            let status = FuzzFiles.launch(arguments, log: out + "/worker.log", environment: ["FZ_WORKER_DIR": work])
            readStats()
            if status == 0 {
                break
            }
            FuzzFiles.removeWork(work)
            restarts += 1
            // 3: the worker grew too big and asked to be replaced.
            if status != 3 {
                fileFinding(status: status)
            }
            writeSummary(final: false)
        }
        writeSummary(final: true)
        FuzzFiles.removeWork(work)
        print("[\(target.name)] done: \(totalExecs) execs, \(restarts) restarts, \(counts.count) signatures")
        for (signature, count) in counts.sorted(by: { $0.key < $1.key }) {
            print("   \(count)x \(signature)")
        }
        exit(0)
    }

    /// The command line of the next worker; empty when the time or the input count is used up.
    private func nextWorkerArguments() -> [String] {
        let left = options.time - Date().timeIntervalSince(started)
        guard left > 1, totalExecs < options.maxExecs else {
            return []
        }
        var arguments = [
            "worker", target.name, "--out", out, "--time", String(left), "--timeout", String(options.timeout),
            "--rss", String(options.rssMB)
        ]
        if options.maxExecs != Int.max {
            arguments += ["--execs", String(options.maxExecs - totalExecs)]
        }
        if let seed = options.seed {
            arguments += ["--seed", String(seed &+ UInt64(restarts))]
        }
        if !options.seedsDir.isEmpty {
            arguments += ["--seeds", options.seedsDir]
        }
        return arguments
    }

    /// Adds up the statistics the worker left in `out/stats`, and removes them.
    private func readStats() {
        guard let text = try? String(contentsOfFile: out + "/stats", encoding: .utf8) else {
            return
        }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            readStat(String(parts[0]), String(parts[1]))
        }
        try? FileManager.default.removeItem(atPath: out + "/stats")
    }

    /// Takes in one line of the worker's statistics.
    private func readStat(_ key: String, _ value: String) {
        switch key {
        case "execs":
            totalExecs += Int(value) ?? 0

        case "edges":
            edges = value

        case "slowest_ms":
            slowest = max(slowest, Double(value) ?? 0)

        case "slowest_ms_per_kb":
            slowestPerKB = max(slowestPerKB, Double(value) ?? 0)

        case "note":
            if !value.isEmpty {
                note = value
            }

        default:
            break
        }
    }

    /// Writes `out/summary.txt`.
    private func writeSummary(final: Bool) {
        var text = """
            target \(target.name)
            execs \(totalExecs)
            restarts \(restarts)
            edges \(edges)
            seconds \(Int(Date().timeIntervalSince(started)))
            slowest_ms \(slowest)
            slowest_ms_per_kb \(slowestPerKB)
            note \(note)
            final \(final)

            """
        for (signature, count) in counts.sorted(by: { $0.key < $1.key }) {
            text += "finding \(count)x \(signature)\n"
        }
        try? text.write(toFile: out + "/summary.txt", atomically: true, encoding: .utf8)
    }

    /// Files the input of a worker that died with `status` under its signature and adds it to the
    /// inputs not to run again.
    private func fileFinding(status: Int32) {
        let log = out + "/worker.log"
        let input = [UInt8](FuzzFiles.read(out + "/current") ?? Data())
        let signature = CrashSignature(log: FuzzFiles.readText(log), status: status).text
        counts[signature, default: 0] += 1
        let dir = out + "/findings/" + FuzzFiles.safeName(signature)
        FuzzFiles.makeFolder(dir)
        keepSmallest(input, log: log, in: dir)
        try? signature.write(toFile: dir + "/signature.txt", atomically: true, encoding: .utf8)
        let line = FuzzFiles.hex(FuzzFiles.fnv(input)) + "\n"
        if let handle = FileHandle(forWritingAtPath: out + "/skip") {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: out + "/skip", atomically: true, encoding: .utf8)
        }
        if restarts % 20 == 1 {
            let progress = "\(counts.count) signatures, \(restarts) restarts, \(totalExecs) execs"
            print("[\(target.name)] \(progress); last: \(signature)")
        }
    }

    /// Keeps `input` (and a copy of the log at `log`) in `dir` when the folder holds fewer than three
    /// inputs or a bigger one, which it replaces.
    private func keepSmallest(_ input: [UInt8], log: String, in dir: String) {
        let name = dir + "/" + FuzzFiles.hex(FuzzFiles.fnv(input)) + ".bin"
        let existing = FuzzFiles.list(dir).filter { $0.hasSuffix(".bin") }
        if existing.count >= 3 {
            let size = { (path: String) in FuzzFiles.read(path)?.count ?? 0 }
            guard let biggest = existing.max(by: { size($0) < size($1) }), size(biggest) > input.count else {
                return
            }
            try? FileManager.default.removeItem(atPath: biggest)
            try? FileManager.default.removeItem(atPath: biggest + ".log")
        }
        FuzzFiles.write(name, input)
        try? FileManager.default.removeItem(atPath: name + ".log")
        try? FileManager.default.copyItem(atPath: log, toPath: name + ".log")
    }

    deinit {
        // Nothing to release: the process ends in `run()`.
    }
}
