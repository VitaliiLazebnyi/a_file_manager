import Foundation
import FuzzC

// A small coverage-guided mutation fuzzer (libFuzzer is not shipped with the Command Line Tools).
//
//   fuzz-X list
//   fuzz-X fuzz <target> --out DIR [--time SECS] [--seeds DIR] [--timeout S] [--rss MB] [--seed N]
//   fuzz-X run  <target> FILE... run inputs once (reproduce)
//   fuzz-X min  <target> FILE OUT         delta-debug a reproducer
//
// `fuzz` is a supervisor: it starts a worker (the same binary), which writes every input to
// DIR/current before running it. When the worker dies, the supervisor files the input under
// DIR/findings/<signature>/ and starts the next worker.

public struct Rng {
    public var s: UInt64
    public init(_ seed: UInt64) { s = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    public mutating func chance(_ oneIn: Int) -> Bool { below(oneIn) == 0 }
    public mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
}

/// Reads choices out of a fuzz input, for targets that build structured values from it.
public struct Choices {
    public let bytes: [UInt8]
    public var at = 0
    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public var atEnd: Bool { at >= bytes.count }
    public mutating func byte() -> UInt8 {
        guard at < bytes.count else { return 0 }
        at += 1
        return bytes[at - 1]
    }
    public mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : (n <= 256 ? Int(byte()) % n : Int(u16()) % n) }
    public mutating func u16() -> UInt16 { UInt16(byte()) | UInt16(byte()) << 8 }
    public mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }
    public mutating func u64() -> UInt64 { UInt64(u32()) | UInt64(u32()) << 32 }
    public mutating func bool() -> Bool { byte() & 1 == 1 }
    public mutating func take(_ n: Int) -> [UInt8] {
        let e = min(bytes.count, at + max(0, n))
        defer { at = e }
        return Array(bytes[at..<e])
    }
    public mutating func rest() -> [UInt8] { take(bytes.count) }
    /// Bytes up to the next occurrence of `sep` (consumed), or the rest.
    public mutating func until(_ sep: UInt8) -> [UInt8] {
        var out: [UInt8] = []
        while at < bytes.count {
            let b = bytes[at]
            at += 1
            if b == sep { break }
            out.append(b)
        }
        return out
    }
}

public let interesting: [UInt64] = [
    0, 1, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x7FFF_FFFF, 0x8000_0000,
    0xFFFF_FFFF, 0x1_0000_0000, 0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, 0xFFFF_FFFF_FFFF_FFFF,
    0xFFFF_FFFE, 0xFFFE, 2, 16, 32, 64, 512, 1_024, 4_096, 65_534, 0xFFFF_FFFF_FFFF_FFFE
]

public enum Mutate {
    public static func put(_ v: UInt64, width: Int, at: Int, bigEndian: Bool, in d: inout [UInt8]) {
        guard at >= 0, at + width <= d.count else { return }
        for i in 0..<width {
            let shift = UInt64(bigEndian ? (width - 1 - i) * 8 : i * 8)
            d[at + i] = UInt8(truncatingIfNeeded: v >> shift)
        }
    }
    public static func get(width: Int, at: Int, bigEndian: Bool, in d: [UInt8]) -> UInt64 {
        guard at >= 0, at + width <= d.count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<width {
            let b = UInt64(d[at + i])
            v |= b << UInt64(bigEndian ? (width - 1 - i) * 8 : i * 8)
        }
        return v
    }

    public static func one(_ d: inout [UInt8], rng: inout Rng, other: [UInt8], dict: [[UInt8]], fields: [Int]) {
        let n = d.count
        switch rng.below(19) {
        case 0: if n > 0 { d[rng.below(n)] ^= 1 << UInt8(rng.below(8)) }
        case 1: if n > 0 { d[rng.below(n)] = UInt8(truncatingIfNeeded: rng.next()) }

        case 2, 3:  // an interesting integer in a 1/2/4/8-byte field, at random or at a known field offset
            let width = [1, 2, 2, 4, 4, 4, 8, 8][rng.below(8)]
            guard n >= width else { break }
            let at = (!fields.isEmpty && rng.chance(2)) ? rng.pick(fields) : rng.below(n - width + 1)
            put(rng.pick(interesting), width: width, at: at, bigEndian: rng.chance(3), in: &d)

        case 4:  // a length field plus or minus a little
            let width = [1, 2, 4, 8][rng.below(4)]
            guard n >= width else { break }
            let at = (!fields.isEmpty && rng.chance(2)) ? rng.pick(fields) : rng.below(n - width + 1)
            let be = rng.chance(3)
            let v = get(width: width, at: at, bigEndian: be, in: d)
            let delta = UInt64(rng.below(4) + 1)
            put(rng.chance(2) ? v &+ delta : v &- delta, width: width, at: at, bigEndian: be, in: &d)

        case 5: if n > 0 { d.removeSubrange(rng.below(n)...) }  // truncate

        case 6:  // remove a block
            guard n > 1 else { break }
            let a = rng.below(n)
            let len = min(n - a, 1 + rng.below(rng.chance(4) ? n : 16))
            d.removeSubrange(a..<a + len)

        case 7:  // duplicate a block
            guard n > 0 else { break }
            let a = rng.below(n)
            let len = min(n - a, 1 + rng.below(rng.chance(4) ? n : 32))
            let block = Array(d[a..<a + len])
            d.insert(contentsOf: block, at: rng.below(n + 1))

        case 8:  // copy a block over another place
            guard n > 1 else { break }
            let a = rng.below(n)
            let len = min(n - a, 1 + rng.below(32))
            let to = rng.below(n)
            let block = Array(d[a..<a + len])
            for (i, b) in block.enumerated() where to + i < d.count { d[to + i] = b }

        case 9:  // insert random bytes
            let len = 1 + rng.below(8)
            d.insert(contentsOf: (0..<len).map { _ in UInt8(truncatingIfNeeded: rng.next()) }, at: rng.below(n + 1))

        case 10:  // insert a run of one byte
            let len = 1 + rng.below(rng.chance(8) ? 4_096 : 64)
            let b: UInt8 =
                rng.chance(2)
                ? rng.pick([0, 0xFF, 0x20, 0x41, 0x2F, 0x0A, 0x30, 0x80, 0x2E, 0x39])
                : UInt8(truncatingIfNeeded: rng.next())
            d.insert(contentsOf: [UInt8](repeating: b, count: len), at: rng.below(n + 1))

        case 11, 12:  // splice with another input
            guard !other.isEmpty else { break }
            let a = rng.below(n + 1)
            let b = rng.below(other.count)
            if rng.chance(2) {
                d = Array(d[..<a]) + other[b...]
            } else {
                let len = min(other.count - b, 1 + rng.below(64))
                d.insert(contentsOf: other[b..<b + len], at: a)
            }

        case 13, 14:  // a dictionary token, inserted or written over
            guard !dict.isEmpty else { break }
            let tok = rng.pick(dict)
            if rng.chance(2) || n < tok.count {
                d.insert(contentsOf: tok, at: rng.below(n + 1))
            } else {
                let at = rng.below(n - tok.count + 1)
                for (i, b) in tok.enumerated() { d[at + i] = b }
            }

        case 15:  // arithmetic on a byte
            if n > 0 {
                let i = rng.below(n)
                d[i] = rng.chance(2) ? d[i] &+ UInt8(1 + rng.below(16)) : d[i] &- UInt8(1 + rng.below(16))
            }

        case 16:  // an ASCII number replaced by an interesting one
            guard n > 0 else { break }
            var a = rng.below(n)
            var tries = 0
            while tries < 64, !(48...57).contains(d[a]) {
                a = (a + 1) % n
                tries += 1
            }
            guard (48...57).contains(d[a]) else { break }
            var e = a
            while e < d.count, (48...57).contains(d[e]) { e += 1 }
            let texts = [
                "0", "1", "-1", "255", "256", "65535", "65536", "2147483647", "2147483648", "4294967295", "4294967296",
                "9223372036854775807", "9223372036854775808", "18446744073709551615", "18446744073709551616",
                "99999999999999999999999999", "00000000000", "7777777777777777777777", "-9223372036854775808"
            ]
            d.replaceSubrange(a..<e, with: Array(rng.pick(texts).utf8))

        case 17:  // swap two blocks
            guard n > 4 else { break }
            let len = 1 + rng.below(min(16, n / 2))
            let a = rng.below(n - len + 1)
            let b = rng.below(n - len + 1)
            for i in 0..<len { d.swapAt(a + i, b + i) }

        default:  // overwrite with a run
            guard n > 0 else { break }
            let a = rng.below(n)
            let len = min(n - a, 1 + rng.below(16))
            let b = UInt8(truncatingIfNeeded: rng.chance(2) ? 0 : rng.next())
            for i in a..<a + len { d[i] = b }
        }
    }
}

public struct FuzzTarget {
    public var name: String
    public var maxLen: Int
    public var dict: [[UInt8]]
    /// Offsets of size/offset fields in an input, for integer mutations aimed at them.
    public var fields: ([UInt8]) -> [Int]
    /// A format-aware mutation, used for a share of the mutants.
    public var custom: ((inout [UInt8], inout Rng) -> Void)?
    public var seeds: () -> [[UInt8]]
    public var setUp: () -> Void
    public var run: ([UInt8]) -> Void
    public init(
        _ name: String, maxLen: Int = 1 << 15, dict: [String] = [], rawDict: [[UInt8]] = [],
        fields: @escaping ([UInt8]) -> [Int] = { _ in [] }, custom: ((inout [UInt8], inout Rng) -> Void)? = nil,
        seeds: @escaping () -> [[UInt8]] = { [] }, setUp: @escaping () -> Void = {}, run: @escaping ([UInt8]) -> Void
    ) {
        self.name = name
        self.maxLen = maxLen
        self.dict = dict.map { Array($0.utf8) } + rawDict
        self.fields = fields
        self.custom = custom
        self.seeds = seeds
        self.setUp = setUp
        self.run = run
    }
}

/// A broken invariant: reported as a finding with `key` as its signature.
public func fzFail(_ key: String, _ detail: String = "") -> Never {
    fz_fail(key + "\n" + String(detail.prefix(4_000)))
}
public func fzCheck(_ ok: @autoclosure () -> Bool, _ key: String, _ detail: @autoclosure () -> String = "") {
    if !ok() { fzFail(key, detail()) }
}

/// Where the running target may write; set for each worker.
public private(set) var fzWorkDir = ""
/// Slowest execution seen by this worker, reported in the stats.
public var fzNote: (String) -> Void = { _ in }

func fnv(_ d: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in d { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return h
}
func hex(_ v: UInt64) -> String { String(v, radix: 16) }
func readFile(_ path: String) -> [UInt8]? { FileManager.default.contents(atPath: path).map { [UInt8]($0) } }
func writeFile(_ path: String, _ d: [UInt8]) { FileManager.default.createFile(atPath: path, contents: Data(d)) }
func listDir(_ path: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted().map { path + "/" + $0 }
}
func mkdir(_ p: String) { try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }

struct Options {
    var out = "", seedsDir: String?, time = 60.0, timeout = 2.0, rssMB = 2_048, seed: UInt64 = 1, maxExecs = Int.max
    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            let v = i + 1 < args.count ? args[i + 1] : ""
            switch a {
            case "--out":
                out = v
                i += 1

            case "--seeds":
                seedsDir = v
                i += 1

            case "--time":
                time = Double(v) ?? 60
                i += 1

            case "--timeout":
                timeout = Double(v) ?? 2
                i += 1

            case "--rss":
                rssMB = Int(v) ?? 2_048
                i += 1

            case "--seed":
                seed = UInt64(v) ?? 1
                i += 1

            case "--execs":
                maxExecs = Int(v) ?? Int.max
                i += 1

            default: break
            }
            i += 1
        }
    }
}

public func fuzzMain(_ targets: [FuzzTarget]) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    let args = Array(CommandLine.arguments.dropFirst())
    guard let mode = args.first else {
        print("usage: list | fuzz <target> --out DIR [--time S] | run <target> FILE... | min <target> FILE OUT")
        exit(2)
    }
    if mode == "list" {
        targets.forEach { print($0.name) }
        exit(0)
    }
    guard args.count >= 2, let target = targets.first(where: { $0.name == args[1] }) else {
        print("unknown target; have: \(targets.map(\.name))")
        exit(2)
    }
    let rest = Array(args.dropFirst(2))
    switch mode {
    case "fuzz": supervise(target, Options(rest))
    case "worker": worker(target, Options(rest))
    case "run": runOnce(target, rest)
    case "min": minimise(target, rest)

    default:
        print("unknown mode")
        exit(2)
    }
}

// MARK: - run once

func runOnce(_ target: FuzzTarget, _ args: [String]) -> Never {
    var files: [String] = []
    var timeout = 2.0
    var rss = 2_048
    var i = 0
    while i < args.count {
        if args[i] == "--timeout", i + 1 < args.count {
            timeout = Double(args[i + 1]) ?? 2
            i += 1
        } else if args[i] == "--rss", i + 1 < args.count {
            rss = Int(args[i + 1]) ?? 2_048
            i += 1
        } else {
            files.append(args[i])
        }
        i += 1
    }
    // Work files go below the system's temporary folder (or where FZ_WORK says), never next to the input.
    fzWorkDir = workBase() + "/fzrun-\(getpid())"
    mkdir(fzWorkDir)
    fz_install_handlers()
    target.setUp()
    fz_watchdog_start(timeout, UInt64(rss) << 20)
    for f in files {
        guard let d = readFile(f) else {
            print("cannot read \(f)")
            continue
        }
        let t = fz_now()
        fz_exec_begin()
        autoreleasepool { target.run(d) }
        fz_exec_end()
        print("ok \(f) \(d.count) bytes \(String(format: "%.1f", (fz_now() - t) * 1_000)) ms")
    }
    removeWork(fzWorkDir)
    exit(0)
}

/// Where the targets may write: `$FZ_WORK`, or `afm-fuzz` in the system's temporary folder.
func workBase() -> String {
    var base = (NSTemporaryDirectory() as NSString).appendingPathComponent("afm-fuzz")
    if let dir = ProcessInfo.processInfo.environment["FZ_WORK"], !dir.isEmpty { base = dir }
    mkdir(base)
    // The real path (/private/var/… for /var/…): targets compare the paths they get back with it.
    if let real = realpath(base, nil) {
        base = String(cString: real)
        free(real)
    }
    return base
}

/// Removes a work folder, also when a target left folders without write permission in it.
func removeWork(_ path: String) {
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
    if (try? FileManager.default.removeItem(atPath: path)) == nil {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+rwx", path]
        chmod.standardError = FileHandle.nullDevice
        if (try? chmod.run()) != nil { chmod.waitUntilExit() }
        try? FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - worker

func worker(_ target: FuzzTarget, _ o: Options) -> Never {
    let out = o.out
    fzWorkDir = ProcessInfo.processInfo.environment["FZ_WORKER_DIR"] ?? workBase() + "/work-\(target.name)-\(getpid())"
    removeWork(fzWorkDir)
    mkdir(fzWorkDir)
    mkdir(out + "/corpus")
    fz_install_handlers()
    target.setUp()
    var skip = Set<UInt64>()
    if let s = try? String(contentsOfFile: out + "/skip", encoding: .utf8) {
        for l in s.split(separator: "\n") { if let v = UInt64(l, radix: 16) { skip.insert(v) } }
    }
    let cur = open(out + "/current", O_RDWR | O_CREAT, 0o644)
    let statFD = open(out + "/stats", O_RDWR | O_CREAT, 0o644)
    var execs = 0
    var slowest = 0.0
    var slowestPerKB = 0.0
    var note = ""
    fzNote = { note = $0 }
    var lastStat = fz_now()
    let started = fz_now()
    let deadline = started + o.time
    func stat(force: Bool = false) {
        let now = fz_now()
        guard force || now - lastStat > 0.5 else { return }
        lastStat = now
        let text =
            "execs \(execs)\nedges \(fz_cov_edges())\nslowest_ms \(String(format: "%.2f", slowest * 1_000))\nslowest_ms_per_kb \(String(format: "%.3f", slowestPerKB * 1_000))\nnote \(note)\n"
        ftruncate(statFD, 0)
        _ = text.withCString { pwrite(statFD, $0, strlen($0), 0) }
    }
    fz_watchdog_start(o.timeout, UInt64(o.rssMB) << 20)
    var slowDir = false
    /// Runs one input; true when it reached something new.
    func exec(_ d: [UInt8]) -> Bool {
        if skip.contains(fnv(d)) { return false }
        ftruncate(cur, 0)
        _ = d.withUnsafeBytes { pwrite(cur, $0.baseAddress, d.count, 0) }
        let t = fz_now()
        fz_exec_begin()
        autoreleasepool { target.run(d) }
        fz_exec_end()
        let dt = fz_now() - t
        execs += 1
        if dt > slowest {
            slowest = dt
            if dt > 0.05 {
                if !slowDir {
                    mkdir(out + "/slow")
                    slowDir = true
                }
                writeFile(out + "/slow/slowest.bin", d)
            }
        }
        if d.count >= 512 { slowestPerKB = max(slowestPerKB, dt / (Double(d.count) / 1_024)) }
        stat()
        return fz_cov_collect() != 0
    }
    fz_cov_reset()
    var corpus: [[UInt8]] = []
    var seen = Set<UInt64>()
    var seedInputs = target.seeds()
    if let dir = o.seedsDir {
        for f in listDir(dir) { if let d = readFile(f), d.count <= target.maxLen { seedInputs.append(d) } }
    }
    let seedCount = seedInputs.count
    for f in listDir(out + "/corpus") { if let d = readFile(f) { seedInputs.append(d) } }
    for (i, d) in seedInputs.enumerated() where seen.insert(fnv(d)).inserted {
        let fresh = exec(d)
        if i < seedCount || fresh { corpus.append(d) }  // seeds always stay; saved inputs only when they still add something
    }
    if corpus.isEmpty { corpus.append([]) }
    let guided = fz_cov_total() > 0
    func keep(_ d: [UInt8]) {
        guard seen.insert(fnv(d)).inserted else { return }
        corpus.append(d)
        writeFile(out + "/corpus/" + hex(fnv(d)), d)
    }

    // Stage 1: every truncation of every seed (once per output directory; progress survives restarts).
    let progressPath = out + "/trunc-progress"
    var progress =
        Int(
            (try? String(contentsOfFile: progressPath, encoding: .utf8))?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? "0") ?? 0
    var index = 0
    outer: for d in seedInputs.prefix(seedCount) where d.count <= 6_000 {
        let step = max(1, d.count / 1_500)
        var len = 0
        while len < d.count {
            if index >= progress {
                if fz_now() > deadline { break outer }
                let m = Array(d[..<len])
                if exec(m) { keep(m) }
                progress = index + 1
                if index % 32 == 0 {
                    try? String(progress).write(toFile: progressPath, atomically: false, encoding: .utf8)
                }
            }
            index += 1
            len += step
        }
    }
    try? String(max(progress, index)).write(toFile: progressPath, atomically: false, encoding: .utf8)

    // Stage 2: random stacked mutations.
    var rng = Rng(o.seed &* 0x1234_5678_9ABC &+ UInt64(getpid()) &+ UInt64(Date().timeIntervalSince1970 * 1_000))
    var baseRSS = fz_rss()
    while fz_now() < deadline, execs < o.maxExecs {
        // newer corpus entries are picked more often
        let base: [UInt8]
        if corpus.count > 8, rng.chance(2) {
            base = corpus[corpus.count - 1 - rng.below(max(1, corpus.count / 5))]
        } else {
            base = rng.pick(corpus)
        }
        var d = base
        let other = rng.pick(corpus)
        var rounds = 1
        while rounds < 16, rng.chance(2) { rounds += 1 }
        for _ in 0..<rounds {
            if let custom = target.custom, rng.chance(4) {
                custom(&d, &rng)
            } else {
                Mutate.one(
                    &d, rng: &rng, other: other, dict: target.dict, fields: rng.chance(3) ? target.fields(d) : [])
            }
        }
        if d.count > target.maxLen { d.removeSubrange(target.maxLen...) }
        if exec(d), guided { keep(d) }
        if execs % 2_048 == 0 {
            // a worker that has grown a lot (leaks, caches) is replaced by a fresh one
            let r = fz_rss()
            if baseRSS == 0 { baseRSS = r }
            if r > UInt64(o.rssMB) << 19 { break }
        }
    }
    stat(force: true)
    removeWork(fzWorkDir)
    exit(fz_now() >= deadline || execs >= o.maxExecs ? 0 : 3)
}

// MARK: - findings

/// What killed a process, from what it wrote: kind plus the top frame inside our binary.
public func signature(ofLog log: String, status: Int32) -> (kind: String, sig: String) {
    let lines = log.components(separatedBy: "\n")
    if let l = lines.first(where: { $0.hasPrefix("FZ-PROPERTY ") }) {
        let k = String(l.dropFirst(12))
        return ("property", "property " + k)
    }
    var kind = "exit\(status)"
    var frames: [String] = []
    if let l = lines.first(where: { $0.contains("ERROR: AddressSanitizer") }) {
        let t = l.components(separatedBy: "AddressSanitizer: ").last ?? ""
        kind = "asan-" + (t.split(separator: " ").first.map(String.init) ?? "error")
        var started = false
        for l in lines {
            let s = l.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#0 ") {
                if started { break }
                started = true
            }
            guard started, s.hasPrefix("#"), let r = s.range(of: " in ") else { continue }
            guard s.contains("(fuzz-") || s.contains(".swift:") else { continue }
            var f = String(s[r.upperBound...])
            if let p = f.range(of: " (") { f = String(f[..<p.lowerBound]) }
            frames.append(f)
        }
    } else {
        if lines.contains(where: { $0.hasPrefix("FZ-TIMEOUT") }) {
            kind = "timeout"
        } else if lines.contains(where: { $0.hasPrefix("FZ-RSS") }) {
            kind = "rss"
        } else if let l = lines.first(where: { $0.hasPrefix("FZ-CRASH") }) {
            kind = "signal" + (l.split(separator: " ").last.map(String.init) ?? "")
        }
        var inTrace = false
        for l in lines {
            if l.hasPrefix("FZ-LOAD") {
                inTrace = true
                continue
            }
            if l.hasPrefix("FZ-END") { break }
            guard inTrace else { continue }
            let parts = l.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, parts[1].hasPrefix("fuzz-") else { continue }
            let sym = String(parts[3])
            if sym.hasPrefix("on_") || sym.hasPrefix("dump ") || sym.hasPrefix("fz_") { continue }
            frames.append(sym)
        }
    }
    // Frames of the fuzzer itself say nothing about the place.
    let own = frames.filter { !$0.contains("8FuzzCore") && !$0.hasPrefix("main") && !$0.contains("FuzzCore.") }
    let top = own.first ?? frames.first ?? "?"
    if kind == "timeout" || kind == "rss" {
        // The interrupted frame is arbitrary; name the outermost project frame below the driver instead.
        let name = own.last.map { $0.components(separatedBy: " + ").first ?? $0 } ?? "?"
        return (kind, kind + " " + name)
    }
    return (kind, kind + " " + top)
}

func safeName(_ s: String) -> String {
    let h = hex(fnv(Array(s.utf8)))
    let head = String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(60))
    return head + "-" + String(h.prefix(8))
}

func launch(_ args: [String], log: String, env: [String: String] = [:]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = args
    FileManager.default.createFile(atPath: log, contents: nil)
    let h = FileHandle(forWritingAtPath: log)!
    p.standardError = h
    p.standardOutput = h
    var e = ProcessInfo.processInfo.environment
    for (k, v) in env { e[k] = v }
    p.environment = e
    do { try p.run() } catch {
        print("cannot start worker: \(error)")
        exit(1)
    }
    p.waitUntilExit()
    try? h.close()
    // A run that was killed could not remove its own work folder.
    if args.first == "run" { removeWork(workBase() + "/fzrun-\(p.processIdentifier)") }
    return p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
}

func supervise(_ target: FuzzTarget, _ o: Options) -> Never {
    let out = o.out
    guard !out.isEmpty else {
        print("--out is required")
        exit(2)
    }
    mkdir(out)
    mkdir(out + "/findings")
    // The data of the running target: below the system's temporary folder, gone when the run ends.
    let work = workBase() + "/work-\(target.name)-\(getpid())"
    defer { removeWork(work) }
    let started = Date()
    var totalExecs = 0
    var restarts = 0
    var edges = "0"
    var slowest = 0.0
    var slowestKB = 0.0
    var note = ""
    var counts: [String: Int] = [:]
    func readStats() {
        guard let s = try? String(contentsOfFile: out + "/stats", encoding: .utf8) else { return }
        for l in s.split(separator: "\n") {
            let p = l.split(separator: " ", maxSplits: 1)
            guard p.count == 2 else { continue }
            switch p[0] {
            case "execs": totalExecs += Int(p[1]) ?? 0
            case "edges": edges = String(p[1])
            case "slowest_ms": slowest = max(slowest, Double(p[1]) ?? 0)
            case "slowest_ms_per_kb": slowestKB = max(slowestKB, Double(p[1]) ?? 0)
            case "note": if !p[1].isEmpty { note = String(p[1]) }
            default: break
            }
        }
        try? FileManager.default.removeItem(atPath: out + "/stats")
    }
    func summary(final: Bool) {
        var text =
            "target \(target.name)\nexecs \(totalExecs)\nrestarts \(restarts)\nedges \(edges)\nseconds \(Int(Date().timeIntervalSince(started)))\n"
        text += "slowest_ms \(slowest)\nslowest_ms_per_kb \(slowestKB)\nnote \(note)\nfinal \(final)\n"
        for (k, v) in counts.sorted(by: { $0.key < $1.key }) { text += "finding \(v)x \(k)\n" }
        try? text.write(toFile: out + "/summary.txt", atomically: true, encoding: .utf8)
    }
    while true {
        let left = o.time - Date().timeIntervalSince(started)
        if left <= 1 { break }
        var args = [
            "worker", target.name, "--out", out, "--time", String(left), "--timeout", String(o.timeout), "--rss",
            String(o.rssMB), "--seed", String(o.seed &+ UInt64(restarts))
        ]
        if let s = o.seedsDir { args += ["--seeds", s] }
        let status = launch(args, log: out + "/worker.log", env: ["FZ_WORKER_DIR": work])
        readStats()
        if status != 0 { removeWork(work) }
        if status == 0 { break }
        restarts += 1
        if status == 3 {
            summary(final: false)
            continue
        }  // voluntary restart
        let log =
            (try? String(contentsOfFile: out + "/worker.log", encoding: .utf8))
            ?? String(decoding: readFile(out + "/worker.log") ?? [], as: UTF8.self)
        let input = readFile(out + "/current") ?? []
        let (_, sig) = signature(ofLog: log, status: status)
        counts[sig, default: 0] += 1
        let dir = out + "/findings/" + safeName(sig)
        mkdir(dir)
        let existing = listDir(dir).filter { $0.hasSuffix(".bin") }
        // keep the three smallest inputs of each signature
        let name = dir + "/" + hex(fnv(input)) + ".bin"
        if existing.count < 3 {
            writeFile(name, input)
            try? log.write(toFile: name + ".log", atomically: true, encoding: .utf8)
        } else if let biggest = existing.max(by: { (readFile($0)?.count ?? 0) < (readFile($1)?.count ?? 0) }),
            (readFile(biggest)?.count ?? 0) > input.count
        {
            try? FileManager.default.removeItem(atPath: biggest)
            try? FileManager.default.removeItem(atPath: biggest + ".log")
            writeFile(name, input)
            try? log.write(toFile: name + ".log", atomically: true, encoding: .utf8)
        }
        try? sig.write(toFile: dir + "/signature.txt", atomically: true, encoding: .utf8)
        if let h = FileHandle(forWritingAtPath: out + "/skip") {
            h.seekToEndOfFile()
            h.write((hex(fnv(input)) + "\n").data(using: .utf8)!)
            try? h.close()
        } else {
            try? (hex(fnv(input)) + "\n").write(toFile: out + "/skip", atomically: true, encoding: .utf8)
        }
        summary(final: false)
        if restarts % 20 == 1 {
            print(
                "[\(target.name)] \(counts.count) signatures, \(restarts) restarts, \(totalExecs) execs; last: \(sig)")
        }
    }
    summary(final: true)
    removeWork(work)
    print("[\(target.name)] done: \(totalExecs) execs, \(restarts) restarts, \(counts.count) signatures")
    for (k, v) in counts.sorted(by: { $0.key < $1.key }) { print("   \(v)x \(k)") }
    exit(0)
}

// MARK: - minimise

func minimise(_ target: FuzzTarget, _ args: [String]) -> Never {
    guard args.count >= 2, var best = readFile(args[0]) else {
        print("min <target> FILE OUT [--timeout S]")
        exit(2)
    }
    let outPath = args[1]
    var extra: [String] = []
    if args.count > 3, args[2] == "--timeout" { extra = ["--timeout", args[3]] }
    let tmp = outPath + ".try"
    let log = outPath + ".trylog"
    var runs = 0
    func sigOf(_ d: [UInt8]) -> String {
        writeFile(tmp, d)
        runs += 1
        let status = launch(["run", target.name, tmp] + extra, log: log)
        if status == 0 { return "" }
        return signature(
            ofLog: (try? String(contentsOfFile: log, encoding: .utf8))
                ?? String(decoding: readFile(log) ?? [], as: UTF8.self), status: status
        ).sig
    }
    let want = sigOf(best)
    guard !want.isEmpty else {
        print("input does not fail")
        exit(1)
    }
    print("signature: \(want); \(best.count) bytes")
    let deadline = Date().addingTimeInterval(240)
    var changed = true
    while changed, Date() < deadline {
        changed = false
        var chunk = max(1, best.count / 2)
        while chunk >= 1, Date() < deadline {
            var at = 0
            while at < best.count, Date() < deadline {
                var c = best
                c.removeSubrange(at..<min(best.count, at + chunk))
                if c.count < best.count, sigOf(c) == want {
                    best = c
                    changed = true
                } else {
                    at += chunk
                }
            }
            if chunk == 1 { break }
            chunk /= 2
        }
        // then simplify the bytes that are left
        if best.count <= 600 {
            for i in 0..<best.count where best[i] != 0 && best[i] != 0x30 && best[i] != 0x61 && Date() < deadline {
                for r: UInt8 in [0, 0x30, 0x61] {
                    var c = best
                    c[i] = r
                    if sigOf(c) == want {
                        best = c
                        break
                    }
                }
            }
        }
    }
    writeFile(outPath, best)
    try? FileManager.default.removeItem(atPath: tmp)
    try? FileManager.default.removeItem(atPath: log)
    print("minimised to \(best.count) bytes in \(runs) runs -> \(outPath)")
    exit(0)
}
