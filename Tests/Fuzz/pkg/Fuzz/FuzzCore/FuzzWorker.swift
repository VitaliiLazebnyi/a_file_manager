internal import Foundation
internal import FuzzC

/// A worker process of `fuzz`: runs the seeds, every truncation of them, then stacked random mutations until its time
/// or input count is used up.
///
/// Before each input it writes the input to `out/current`, so that the supervisor can file it when the worker dies.
@MainActor
internal final class FuzzWorker {
    /// The target fuzzed.
    private let target: FuzzTarget
    /// The command-line options.
    private let options: FuzzOptions
    /// The output folder.
    private let out: String
    /// When the worker stops; set when the target is ready.
    private var deadline = 0.0
    /// Hashes of inputs that made earlier workers fail; they are not run again.
    private var skip = Set<UInt64>()
    /// Hashes of every input kept or tried from the seeds.
    private var seen = Set<UInt64>()
    /// The inputs mutations start from.
    private var corpus: [[UInt8]] = []
    /// `out/current`, rewritten before each input.
    private var currentFile: Int32 = -1
    /// `out/stats`, rewritten at most twice a second.
    private var statsFile: Int32 = -1
    /// Inputs run.
    private var execs = 0
    /// Seconds of the slowest input.
    private var slowest = 0.0
    /// Seconds per KiB of the slowest input of at least 512 bytes.
    private var slowestPerKB = 0.0
    /// The target's note for the statistics (`fzNote`).
    private var note = ""
    /// When the statistics were last written.
    private var lastStats = 0.0
    /// Whether `out/slow` exists.
    private var madeSlowFolder = false

    /// Whether the time or the input count is used up.
    private var isDone: Bool {
        fz_now() >= deadline || execs >= options.maxExecs
    }

    /// A worker for `target` with the given options.
    internal init(target: FuzzTarget, options: FuzzOptions) {
        self.target = target
        self.options = options
        out = options.out
    }

    /// Fuzzes until the time or the input count is used up, then exits: 0 when it is, 3 when the
    /// worker grew too big and wants to be replaced.
    internal func run() -> Never {
        let work = ProcessInfo.processInfo.environment["FZ_WORKER_DIR"]
        fzWorkDir = work ?? FuzzFiles.workBase() + "/work-\(target.name)-\(getpid())"
        FuzzFiles.removeWork(fzWorkDir)
        FuzzFiles.makeFolder(fzWorkDir)
        FuzzFiles.makeFolder(out + "/corpus")
        fz_install_handlers()
        target.setUp()
        loadSkipList()
        currentFile = open(out + "/current", O_RDWR | O_CREAT, 0o644)
        statsFile = open(out + "/stats", O_RDWR | O_CREAT, 0o644)
        fzNote = { [weak self] text in
            self?.note = text
        }
        lastStats = fz_now()
        deadline = lastStats + options.time
        fz_watchdog_start(options.timeout, UInt64(options.rssMB) << 20)
        fz_cov_reset()
        let seeds = runSeeds()
        let guided = fz_cov_total() > 0
        truncateSeeds(seeds, guided: guided)
        mutate(guided: guided)
        writeStats(force: true)
        FuzzFiles.removeWork(fzWorkDir)
        exit(isDone ? 0 : 3)
    }

    /// Reads `out/skip`, the inputs that made earlier workers fail.
    private func loadSkipList() {
        guard let text = try? String(contentsOfFile: out + "/skip", encoding: .utf8) else {
            return
        }
        for line in text.split(separator: "\n") {
            if let hash = UInt64(line, radix: 16) {
                skip.insert(hash)
            }
        }
    }

    /// Writes the statistics for the supervisor, at most twice a second unless `force` is set.
    private func writeStats(force: Bool) {
        let now = fz_now()
        guard force || now - lastStats > 0.5 else {
            return
        }
        lastStats = now
        let text = """
            execs \(execs)
            edges \(fz_cov_edges())
            slowest_ms \(String(format: "%.2f", slowest * 1_000))
            slowest_ms_per_kb \(String(format: "%.3f", slowestPerKB * 1_000))
            note \(note)

            """
        ftruncate(statsFile, 0)
        _ = text.withCString { pwrite(statsFile, $0, strlen($0), 0) }
    }

    /// Runs one input; true when it reached something new.
    private func exec(_ data: [UInt8]) -> Bool {
        if skip.contains(FuzzFiles.fnv(data)) {
            return false
        }
        ftruncate(currentFile, 0)
        _ = data.withUnsafeBytes { pwrite(currentFile, $0.baseAddress, data.count, 0) }
        let started = fz_now()
        fz_exec_begin()
        autoreleasepool {
            target.run(data)
        }
        fz_exec_end()
        let seconds = fz_now() - started
        execs += 1
        noteDuration(seconds, of: data)
        writeStats(force: false)
        return fz_cov_collect() != 0
    }

    /// Remembers the slowest input; one slower than 50 ms is kept as `out/slow/slowest.bin`.
    private func noteDuration(_ seconds: Double, of data: [UInt8]) {
        if seconds > slowest {
            slowest = seconds
            if seconds > 0.05 {
                if !madeSlowFolder {
                    FuzzFiles.makeFolder(out + "/slow")
                    madeSlowFolder = true
                }
                FuzzFiles.write(out + "/slow/slowest.bin", data)
            }
        }
        if data.count >= 512 {
            slowestPerKB = max(slowestPerKB, seconds / (Double(data.count) / 1_024))
        }
    }

    /// Adds an input that reached something new to the corpus and saves it.
    private func keep(_ data: [UInt8]) {
        guard seen.insert(FuzzFiles.fnv(data)).inserted else {
            return
        }
        corpus.append(data)
        FuzzFiles.write(out + "/corpus/" + FuzzFiles.hex(FuzzFiles.fnv(data)), data)
    }

    /// Runs the target's seeds, those of `--seeds` and the saved corpus, and fills the corpus.
    ///
    /// Returns the seeds (without the saved corpus).
    private func runSeeds() -> [[UInt8]] {
        var inputs = target.seeds()
        if !options.seedsDir.isEmpty {
            for file in FuzzFiles.list(options.seedsDir) {
                if let data = FuzzFiles.read(file), data.count <= target.maxLen {
                    inputs.append([UInt8](data))
                }
            }
        }
        let seedCount = inputs.count
        for file in FuzzFiles.list(out + "/corpus") {
            if let data = FuzzFiles.read(file) {
                inputs.append([UInt8](data))
            }
        }
        for (index, data) in inputs.enumerated() where seen.insert(FuzzFiles.fnv(data)).inserted {
            let fresh = exec(data)
            // Seeds always stay; saved inputs only when they still add something.
            if index < seedCount || fresh {
                corpus.append(data)
            }
        }
        if corpus.isEmpty {
            corpus.append([])
        }
        return Array(inputs.prefix(seedCount))
    }

    /// Stage 1: every truncation of every seed (once per output folder; the progress survives
    /// restarts).
    private func truncateSeeds(_ seeds: [[UInt8]], guided: Bool) {
        let progressPath = out + "/trunc-progress"
        let saved = try? String(contentsOfFile: progressPath, encoding: .utf8)
        var progress = Int(saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        var index = 0
        outer: for seed in seeds where seed.count <= 6_000 {
            let step = max(1, seed.count / 1_500)
            for length in stride(from: 0, to: seed.count, by: step) {
                if index >= progress {
                    if isDone {
                        break outer
                    }
                    let truncated = Array(seed[..<length])
                    if exec(truncated), guided {
                        keep(truncated)
                    }
                    progress = index + 1
                    if index.isMultiple(of: 32) {
                        try? String(progress).write(toFile: progressPath, atomically: false, encoding: .utf8)
                    }
                }
                index += 1
            }
        }
        try? String(max(progress, index)).write(toFile: progressPath, atomically: false, encoding: .utf8)
    }

    /// Stage 2: stacked random mutations of corpus inputs, newer ones picked more often.
    private func mutate(guided: Bool) {
        var rng = makeRng()
        while !isDone {
            var data = pickBase(&rng)
            let other = rng.pick(corpus)
            var rounds = 1
            while rounds < 16, rng.chance(2) {
                rounds += 1
            }
            for _ in 0..<rounds {
                mutateOnce(&data, other: other, &rng)
            }
            if data.count > target.maxLen {
                data.removeSubrange(target.maxLen...)
            }
            if exec(data), guided {
                keep(data)
            }
            // A worker that has grown a lot (leaks, caches) is replaced by a fresh one.
            if execs.isMultiple(of: 2_048), fz_rss() > UInt64(options.rssMB) << 19 {
                break
            }
        }
    }

    /// The input a mutation starts from: one of the newest fifth of the corpus half of the time.
    private func pickBase(_ rng: inout Rng) -> [UInt8] {
        if corpus.count > 8, rng.chance(2) {
            return corpus[corpus.count - 1 - rng.below(max(1, corpus.count / 5))]
        }
        return rng.pick(corpus)
    }

    /// One mutation: the target's own a quarter of the time, a generic one otherwise.
    private func mutateOnce(_ data: inout [UInt8], other: [UInt8], _ rng: inout Rng) {
        if let custom = target.custom, rng.chance(4) {
            custom(&data, &rng)
        } else {
            let fields = rng.chance(3) ? target.fields(data) : []
            Mutate.one(&data, rng: &rng, other: other, dict: target.dict, fields: fields)
        }
    }

    /// The generator of the mutations: from `--seed` when given (the same mutations on every run),
    /// else from the seed, the process number and the time.
    private func makeRng() -> Rng {
        if let seed = options.seed {
            return Rng(seed)
        }
        let millis = UInt64(Date().timeIntervalSince1970 * 1_000)
        return Rng(0x1234_5678_9ABC &+ UInt64(getpid()) &+ millis)
    }

    deinit {
        // Nothing to release: the process ends in `run()`.
    }
}
