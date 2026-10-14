import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import StressKit
import TestSupport

@testable import AFMShell
@testable import FileOperationsPlugin

// Scenario 4: FileJob under random cancel / pause / resume, on a real tree and on a
// destination that keeps writes back (`.deferredWrites`) with commits that fail at random.
//
// The jobs run through the shell's real ProgressJobService (pause gate, progress reports to
// the main thread, questions through `JobMonitor.ask`), with the main run loop pumping and the
// watchdog measuring it.

// MARK: Arguments

var arguments: [String: String] = [:]
do {
    var rest = Array(CommandLine.arguments.dropFirst())
    while !rest.isEmpty {
        let key = rest.removeFirst()
        arguments[key] = rest.isEmpty || rest[0].hasPrefix("--") ? "1" : rest.removeFirst()
    }
}
func argument(_ name: String, _ fallback: Int) -> Int { arguments[name].flatMap(Int.init) ?? fallback }
let rootPath = arguments["--root"] ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("afm-stress/jobs")
let root = URL(fileURLWithPath: rootPath)
let fileCount = argument("--files", 100_000)
let folderCount = argument("--folders", 2_000)
let bigCount = argument("--big", 12)
let seedCount = argument("--seeds", 50)
let seedBase = argument("--seedbase", 1)
let memSeeds = argument("--memseeds", 0)
let skipLocal = arguments["--skiplocal"] != nil
let keepTree = arguments["--keep"] != nil
let results = arguments["--results"] ?? FileManager.default.currentDirectoryPath

// MARK: The tree

struct Entry {
    let path: String
    let index: Int
    let size: Int
}

func bytes(index: Int, size: Int) -> Data {
    var data = Data(count: size)
    data.withUnsafeMutableBytes { raw in
        let buffer = raw.bindMemory(to: UInt8.self)
        var state = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15 &+ 12_345
        var position = 0
        while position < size {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var word = state
            var count = min(8, size - position)
            while count > 0 {
                buffer[position] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                position += 1
                count -= 1
            }
        }
    }
    return data
}

func makeManifest() -> [Entry] {
    var entries: [Entry] = []
    entries.reserveCapacity(fileCount + bigCount)
    let perFolder = max(1, fileCount / folderCount)
    for index in 0..<fileCount {
        let folder = min(folderCount - 1, index / perFolder)
        entries.append(
            Entry(
                path: String(format: "d%04d/f%06d.dat", folder, index), index: index,
                size: 16 + (index &* 7_919) % 2_048
            ))
    }
    // Larger than FileJob.smallFileLimit (4 MB): copied one after another, as a stream.
    for index in 0..<bigCount {
        entries.append(
            Entry(
                path: String(format: "big/b%02d.bin", index), index: fileCount + index,
                size: (5 << 20) + index * (1 << 20) + 17))
    }
    return entries
}

let manifest = makeManifest()
let fm = FileManager.default

func parallel(_ count: Int, _ body: @escaping (Int) -> Void) {
    DispatchQueue.concurrentPerform(iterations: count, execute: body)
}

func buildTree(at base: URL, entries: [Entry]) {
    var folders = Set<String>()
    for entry in entries { folders.insert((entry.path as NSString).deletingLastPathComponent) }
    for folder in folders {
        try! fm.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let chunk = 256
    parallel((entries.count + chunk - 1) / chunk) { piece in
        for position in (piece * chunk)..<min(entries.count, (piece + 1) * chunk) {
            let entry = entries[position]
            let path = base.path + "/" + entry.path
            let data = bytes(index: entry.index, size: entry.size)
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            precondition(fd >= 0, "cannot create \(path)")
            data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
    }
}

enum Found {
    case missing, identical
    case different(Int)
}

func look(_ base: String, _ entry: Entry) -> Found {
    let path = base + "/" + entry.path
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return .missing }
    defer { close(fd) }
    var status = stat()
    fstat(fd, &status)
    guard Int(status.st_size) == entry.size else { return .different(Int(status.st_size)) }
    var content = Data(count: entry.size)
    let got = content.withUnsafeMutableBytes { raw -> Int in
        var total = 0
        while total < entry.size {
            let n = read(fd, raw.baseAddress! + total, entry.size - total)
            if n <= 0 { break }
            total += n
        }
        return total
    }
    guard got == entry.size else { return .different(got) }
    return content == bytes(index: entry.index, size: entry.size) ? .identical : .different(entry.size)
}

/// 0 missing, 1 identical, 2 different, for every entry.
func survey(_ base: URL, entries: [Entry] = manifest) -> [UInt8] {
    var states = [UInt8](repeating: 0, count: entries.count)
    let chunk = 512
    states.withUnsafeMutableBufferPointer { buffer in
        let slots = buffer.baseAddress!
        DispatchQueue.concurrentPerform(iterations: (entries.count + chunk - 1) / chunk) { piece in
            for position in (piece * chunk)..<min(entries.count, (piece + 1) * chunk) {
                switch look(base.path, entries[position]) {
                case .missing: slots[position] = 0
                case .identical: slots[position] = 1
                case .different: slots[position] = 2
                }
            }
        }
    }
    return states
}

/// Every path below `base` (relative), files and folders apart.
func walk(_ base: URL) -> (files: [String], folders: [String]) {
    var files: [String] = []
    var folders: [String] = []
    func visit(_ path: String, _ relative: String) {
        guard let dir = opendir(path) else { return }
        var subfolders: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let rel = relative.isEmpty ? name : relative + "/" + name
            if entry.pointee.d_type == DT_DIR {
                folders.append(rel)
                subfolders.append(name)
            } else {
                files.append(rel)
            }
        }
        closedir(dir)
        for name in subfolders { visit(path + "/" + name, relative.isEmpty ? name : relative + "/" + name) }
    }
    visit(base.path, "")
    return (files, folders)
}

func isTemporary(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    return name.hasPrefix(".afm-") && name.hasSuffix(".tmp")
}

// MARK: Findings

final class Findings {
    private let lock = NSLock()
    private(set) var violations: [String: Int] = [:]
    private var examples: [String: [String]] = [:]

    func violation(_ kind: String, _ detail: String) {
        lock.lock()
        violations[kind, default: 0] += 1
        if examples[kind, default: []].count < 6 {
            examples[kind, default: []].append(detail)
            lock.unlock()
            say("!! VIOLATION [\(kind)] \(detail)")
        } else {
            lock.unlock()
        }
    }

    func summary() {
        say("\n==== INVARIANT VIOLATIONS ====")
        if violations.isEmpty { say("none") }
        for (kind, count) in violations.sorted(by: { $0.key < $1.key }) {
            say("\(kind): \(count)")
            for example in examples[kind] ?? [] { say("    e.g. \(example)") }
        }
    }
}

let findings = Findings()

// MARK: The job's delegate

/// Answers like a user who says yes to everything, through the monitor (as JobBridge does),
/// and checks that the progress never goes backwards.
final class Recorder: FileJobDelegate {
    let monitor: JobMonitor
    let label: String
    private let lock = NSLock()
    private var last: JobProgress?
    private(set) var reports = 0
    private(set) var backwards = 0
    private(set) var errors: [String] = []
    private(set) var questions = 0
    var errorAnswer: ErrorChoice = .skip

    init(monitor: JobMonitor, label: String) {
        self.monitor = monitor
        self.label = label
    }

    func job(_: FileJob, progress: JobProgress) {
        lock.lock()
        reports += 1
        if let last {
            if progress.itemsDone < last.itemsDone || progress.bytesDone < last.bytesDone {
                backwards += 1
                if backwards <= 3 {
                    findings.violation(
                        "progress went backwards",
                        "\(label): items \(last.itemsDone)->\(progress.itemsDone) bytes \(last.bytesDone)->\(progress.bytesDone) totals \(progress.itemsTotal)/\(progress.bytesTotal)"
                    )
                }
            }
            if progress.itemsTotal != last.itemsTotal || progress.bytesTotal != last.bytesTotal {
                // Not a violation by itself (totals may be corrected); counted for the record.
            }
        }
        if progress.itemsDone > progress.itemsTotal || progress.bytesDone > progress.bytesTotal {
            findings.violation(
                "progress beyond total",
                "\(label): items \(progress.itemsDone)/\(progress.itemsTotal) bytes \(progress.bytesDone)/\(progress.bytesTotal)"
            )
        }
        last = progress
        lock.unlock()
        monitor.report(progress)
    }

    var lastProgress: JobProgress? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func job(_: FileJob, conflictAt _: FileItem, source _: FileItem) -> ConflictChoice {
        lock.lock()
        questions += 1
        lock.unlock()
        return monitor.ask { .overwriteAll }
    }

    func job(_: FileJob, failedAt url: URL, error: Error) -> ErrorChoice {
        lock.lock()
        questions += 1
        errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
        let answer = errorAnswer
        lock.unlock()
        return monitor.ask { answer }
    }

    func job(_: FileJob, confirmDeleteNonEmpty _: URL) -> FolderDeleteChoice {
        lock.lock()
        questions += 1
        lock.unlock()
        return monitor.ask { .all }
    }

    func job(_: FileJob, confirm _: ProtectionQuestion) -> ProtectionChoice { monitor.ask { .all } }
    func job(_: FileJob, mergeInto _: FileItem, source _: FileItem) -> MergeChoice {
        monitor.ask { .mergeAll }
    }
}

// MARK: Running one job with interference

struct Interference {
    var cancelAfter: Double?
    var pauses = false
    /// Cancel from the controller's own thread (the handle) instead of through the main thread.
    var cancelsOffMain = false
}

struct Outcome {
    var result = JobResult()
    var wall = 0.0
    var reports = 0
    var errors: [String] = []
    var pauses = 0
    var cancelSent = false
    var last: JobProgress?
}

let jobService = ProgressJobService()

final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Runs the job through the job service while another thread pauses, resumes and cancels it.
/// Main thread; pumps the run loop until the job's completion was called.
func runJob(
    _ label: String, seed: UInt64, interference: Interference, limit: Double = 180,
    configure: @escaping (FileJob) -> Void = { _ in },
    make: @escaping (CancellationFlag) -> FileJob
) -> Outcome {
    var outcome = Outcome()
    let finished = Box(false)
    let recorderBox = Box<Recorder?>(nil)
    let started = now()
    HangGuard.shared.arm(label, seconds: limit)
    let handle = jobService.run(
        title: label,
        work: { monitor -> JobResult in
            let job = make(monitor.cancellation)
            let recorder = Recorder(monitor: monitor, label: label)
            recorderBox.value = recorder
            job.delegate = recorder
            job.progressInterval = 0.04
            configure(job)
            return withExtendedLifetime(recorder) { job.run() }
        },
        completion: { result in
            outcome.result = result
            finished.value = true
        })

    let stop = CancellationFlag()
    let pauseCount = Box(0)
    let cancelSent = Box(false)
    let controller = Thread {
        var random = Random(seed: seed)
        let begun = now()
        var paused = false
        while !stop.isCancelled {
            usleep(UInt32.random(in: 500...12_000, using: &random))
            if stop.isCancelled { break }
            let elapsed = now() - begun
            if let at = interference.cancelAfter, elapsed >= at, !cancelSent.value {
                cancelSent.value = true
                if interference.cancelsOffMain {
                    handle.cancel()
                } else {
                    DispatchQueue.main.async { jobService.cancelCurrent() }
                }
                continue
            }
            guard interference.pauses else { continue }
            if paused {
                // Resume after a short while.
                if Int.random(in: 0..<3, using: &random) > 0 {
                    paused = false
                    DispatchQueue.main.async { jobService.setPaused(false) }
                }
            } else if Int.random(in: 0..<12, using: &random) == 0 {
                paused = true
                pauseCount.value += 1
                DispatchQueue.main.async { jobService.setPaused(true) }
            }
        }
    }
    controller.name = "Stress.Controller"
    controller.start()

    pump(upTo: limit + 30) { finished.value }
    stop.cancel()
    HangGuard.shared.disarm()
    outcome.wall = now() - started
    outcome.pauses = pauseCount.value
    outcome.cancelSent = cancelSent.value
    if let recorder = recorderBox.value {
        outcome.reports = recorder.reports
        outcome.errors = recorder.errors
        outcome.last = recorder.lastProgress
    }
    if jobService.isBusy { findings.violation("job service still busy after completion", label) }
    return outcome
}

/// Runs `body` on a background thread while the main run loop goes on.
func offMain<T>(_ body: @escaping () -> T) -> T {
    let done = Box<T?>(nil)
    let thread = Thread {
        let value = body()
        DispatchQueue.main.async { done.value = value }
    }
    thread.stackSize = 16 << 20
    thread.start()
    pump(upTo: 3_600) { done.value != nil }
    return done.value!
}

func describe(_ kind: String, _ seed: Int, _ outcome: Outcome, _ interference: Interference) -> String {
    let cancel =
        interference.cancelAfter.map { String(format: "%.3fs%@", $0, interference.cancelsOffMain ? "(bg)" : "(main)") }
        ?? "-"
    return String(
        format:
            "RUN seed=%d %@ wall=%.2fs cancelAt=%@ sent=%@ cancelled=%@ completed=%d failures=%d reports=%d pauses=%d threads=%d",
        seed, kind, outcome.wall, cancel, outcome.cancelSent ? "y" : "n", outcome.result.cancelled ? "y" : "n",
        outcome.result.completed.count, outcome.result.failureCount, outcome.reports, outcome.pauses, threadCount())
}

// MARK: Start

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
HangGuard.shared.sampleDirectory = results
MainWatchdog.shared.start()
say(
    "StressJobs root=\(root.path) files=\(fileCount) folders=\(folderCount) big=\(bigCount) seeds=\(seedCount) memseeds=\(memSeeds) cores=\(ProcessInfo.processInfo.activeProcessorCount) load=\(loadAverage())"
)

let fileSystems = FileSystemRegistry()
fileSystems.register(LocalFileSystem())

let source = root.appendingPathComponent("src")
let destination = root.appendingPathComponent("dst")
let moved = root.appendingPathComponent("moved")

func topLevel(_ base: URL) -> [URL] {
    // Every top-level entry of the trees is a folder; saying so spares a stat per name.
    ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).sorted().map {
        URL(fileURLWithPath: base.path + "/" + $0, isDirectory: true)
    }
}

func removeQuickly(_ url: URL) {
    guard fm.fileExists(atPath: url.path) else { return }
    let children = topLevel(url)
    parallel(children.count) { try? fm.removeItem(at: children[$0]) }
    try? fm.removeItem(at: url)
}

step("idle baseline") { pump(for: 1.5) }

var durations: [String: [Double]] = [:]
var threadsAfter: [Int] = []
var baselineThreads = 0
var maxThreads = 0

func note(_ kind: String, _ outcome: Outcome) {
    durations[kind, default: []].append(outcome.wall)
    maxThreads = max(maxThreads, threadCount())
}

func checkErrors(_ label: String, _ outcome: Outcome) {
    // Errors are only expected as a consequence of a cancel (and then they should not be asked about at all).
    for error in outcome.errors.prefix(3) { findings.violation("job reported an error", "\(label): \(error)") }
    if outcome.result.failureCount > 0 {
        findings.violation(
            "job counted failures", "\(label): \(outcome.result.failureCount) \(outcome.result.failures.prefix(2))")
    }
}

func checkNoTemporaries(_ label: String, _ bases: [URL]) -> [String: (files: [String], folders: [String])] {
    var all: [String: (files: [String], folders: [String])] = [:]
    for base in bases {
        let found = walk(base)
        all[base.lastPathComponent] = found
        for path in found.files + found.folders where isTemporary(path) {
            findings.violation("temporary file left behind", "\(label): \(base.lastPathComponent)/\(path)")
        }
    }
    return all
}

if !skipLocal {
    step("build tree", limit: 900) {
        offMain {
            if fm.fileExists(atPath: source.path), survey(source).allSatisfy({ $0 == 1 }) {
                say("tree exists and is intact")
            } else {
                removeQuickly(source)
                try! fm.createDirectory(at: source, withIntermediateDirectories: true)
                buildTree(at: source, entries: manifest)
            }
            removeQuickly(destination)
            removeQuickly(moved)
        }
    }
    let totalBytes = manifest.reduce(0) { $0 + $1.size }
    say("tree: \(manifest.count) files, \(folderCount) folders (+big), \(totalBytes >> 20) MB")
    let manifestPaths = Set(manifest.map(\.path))

    // Uninterrupted runs first: the rates, and how long a run takes (for choosing when to cancel).
    var estimate: [String: Double] = [:]

    func copyRun(seed: Int, _ interference: Interference) -> Outcome {
        let sources = offMain { topLevel(source) }
        MainWatchdog.shared.setPhase("copy")
        let outcome = runJob("copy#\(seed)", seed: UInt64(seed), interference: interference) { flag in
            let job = FileJob(
                kind: .copy, sources: sources, target: TargetSpec(directory: destination), fileSystems: fileSystems,
                cancellation: flag)
            job.options.overwrite = .overwriteAll
            return job
        }
        say(describe("copy", seed, outcome, interference))
        note("copy", outcome)
        MainWatchdog.shared.setPhase("verify (harness)")
        offMain {
            checkErrors("copy#\(seed)", outcome)
            let (src, dst) = (survey(source), survey(destination))
            var lost = 0
            var damaged = 0
            var partial = 0
            var missingAfterFullRun = 0
            for index in manifest.indices {
                if src[index] == 0 { lost += 1 }
                if src[index] == 2 { damaged += 1 }
                if dst[index] == 2 { partial += 1 }
                if dst[index] == 0, !outcome.result.cancelled { missingAfterFullRun += 1 }
            }
            if lost > 0 { findings.violation("copy: source file gone", "seed \(seed): \(lost) files") }
            if damaged > 0 { findings.violation("copy: source file changed", "seed \(seed): \(damaged) files") }
            if partial > 0 {
                let example = manifest.indices.first { dst[$0] == 2 }.map { manifest[$0].path } ?? ""
                findings.violation(
                    "copy: partial/different file under its final name",
                    "seed \(seed) cancelled=\(outcome.result.cancelled): \(partial) files, e.g. \(example)")
            }
            if missingAfterFullRun > 0 {
                findings.violation(
                    "copy: finished without cancel but files missing at target", "seed \(seed): \(missingAfterFullRun)"
                )
            }
            let trees = checkNoTemporaries("copy#\(seed)", [source, destination])
            let extra = (trees["dst"]?.files ?? []).filter { !manifestPaths.contains($0) && !isTemporary($0) }
            if !extra.isEmpty {
                findings.violation("copy: unexpected file at target", "seed \(seed): \(extra.count), e.g. \(extra[0])")
            }
            if !outcome.result.cancelled, outcome.result.completed.count != sources.count {
                findings.violation(
                    "copy: not every source reported completed",
                    "seed \(seed): \(outcome.result.completed.count)/\(sources.count)")
            }
        }
        return outcome
    }

    func deleteRun(seed: Int, _ interference: Interference) -> Outcome {
        let sources = offMain { topLevel(destination) }
        let before = offMain { survey(destination) }
        MainWatchdog.shared.setPhase("delete")
        let outcome = runJob("delete#\(seed)", seed: UInt64(seed) &* 31 &+ 7, interference: interference) { flag in
            FileJob(kind: .delete(toTrash: false), sources: sources, fileSystems: fileSystems, cancellation: flag)
        }
        say(describe("delete", seed, outcome, interference))
        note("delete", outcome)
        MainWatchdog.shared.setPhase("verify (harness)")
        offMain {
            checkErrors("delete#\(seed)", outcome)
            let (src, dst) = (survey(source), survey(destination))
            let lost = src.filter { $0 != 1 }.count
            if lost > 0 {
                findings.violation("delete: a file outside the deleted folder was touched", "seed \(seed): \(lost)")
            }
            var damaged = 0
            var left = 0
            for index in manifest.indices {
                if dst[index] == 2 || (dst[index] == 1 && before[index] != 1) { damaged += 1 }
                if dst[index] != 0 { left += 1 }
            }
            if damaged > 0 { findings.violation("delete: file left damaged", "seed \(seed): \(damaged)") }
            if !outcome.result.cancelled, left > 0 {
                findings.violation("delete: finished without cancel but files remain", "seed \(seed): \(left)")
            }
            if !outcome.result.cancelled, !topLevel(destination).isEmpty {
                findings.violation(
                    "delete: finished without cancel but folders remain",
                    "seed \(seed): \(topLevel(destination).count)")
            }
            _ = checkNoTemporaries("delete#\(seed)", [destination])
        }
        return outcome
    }

    /// Half of the folders exist at the target already, so that their files are moved one by
    /// one (a merge); the others go with one rename each.
    func moveRun(seed: Int, _ interference: Interference, back: Bool) -> Outcome {
        let (from, to) = back ? (moved, source) : (source, moved)
        let kind = back ? "move-back" : "move"
        offMain {
            if !back {
                try? fm.createDirectory(at: moved, withIntermediateDirectories: true)
                for folder in 0..<folderCount where (folder + seed) % 2 == 0 {
                    try? fm.createDirectory(
                        at: moved.appendingPathComponent(String(format: "d%04d", folder)),
                        withIntermediateDirectories: true)
                }
                if seed % 2 == 0 {
                    try? fm.createDirectory(at: moved.appendingPathComponent("big"), withIntermediateDirectories: true)
                }
            } else {
                // A third of the folders exist at the source again: their files come back one by one.
                for folder in 0..<folderCount where (folder + seed) % 3 == 0 {
                    try? fm.createDirectory(
                        at: source.appendingPathComponent(String(format: "d%04d", folder)),
                        withIntermediateDirectories: true)
                }
            }
        }
        let sources = offMain { topLevel(from) }
        MainWatchdog.shared.setPhase(kind)
        let outcome = runJob(
            "\(kind)#\(seed)", seed: UInt64(seed) &* 131 &+ (back ? 5 : 3), interference: interference
        ) { flag in
            let job = FileJob(
                kind: .move, sources: sources, target: TargetSpec(directory: to), fileSystems: fileSystems,
                cancellation: flag)
            job.options.overwrite = .overwriteAll
            return job
        }
        say(describe(kind, seed, outcome, interference))
        note(kind, outcome)
        MainWatchdog.shared.setPhase("verify (harness)")
        offMain {
            checkErrors("\(kind)#\(seed)", outcome)
            let (a, b) = (survey(source), survey(moved))
            var lost = 0
            var damaged = 0
            var both = 0
            var notMoved = 0
            var example = ""
            for index in manifest.indices {
                if a[index] == 2 || b[index] == 2 {
                    damaged += 1
                    if example.isEmpty { example = manifest[index].path }
                }
                if a[index] == 0, b[index] == 0 {
                    lost += 1
                    if example.isEmpty { example = manifest[index].path }
                }
                if a[index] == 1, b[index] == 1 { both += 1 }
                if (back ? b[index] : a[index]) != 0 { notMoved += 1 }
            }
            if lost > 0 {
                findings.violation(
                    "\(kind): FILE LOST (neither at source nor at target)",
                    "seed \(seed) cancelled=\(outcome.result.cancelled): \(lost) files, e.g. \(example)")
            }
            if damaged > 0 {
                findings.violation(
                    "\(kind): file damaged/partial under its name",
                    "seed \(seed) cancelled=\(outcome.result.cancelled): \(damaged), e.g. \(example)")
            }
            if both > 0 {
                say("note: \(kind)#\(seed): \(both) files exist at both ends (cancelled=\(outcome.result.cancelled))")
            }
            if !outcome.result.cancelled, notMoved > 0 {
                findings.violation(
                    "\(kind): finished without cancel but files remain at the source", "seed \(seed): \(notMoved)")
            }
            _ = checkNoTemporaries("\(kind)#\(seed)", [source, moved])
        }
        return outcome
    }

    func interference(_ kind: String, _ random: inout Random) -> Interference {
        var result = Interference()
        let expected = estimate[kind] ?? 5
        // Six runs in ten are cancelled, somewhere between the start and the expected end.
        if Int.random(in: 0..<10, using: &random) < 6 {
            result.cancelAfter = Double.random(in: 0...(expected * 1.1), using: &random)
        }
        result.pauses = Int.random(in: 0..<10, using: &random) < 7
        result.cancelsOffMain = Bool.random(using: &random)
        return result
    }

    step("calibration: uninterrupted copy/delete/move", limit: 900) {
        let copy = copyRun(seed: 0, Interference())
        estimate["copy"] = copy.wall
        say(
            String(
                format: "RATE copy: %.0f files/s, %.1f MB/s", Double(manifest.count) / copy.wall,
                Double(totalBytes) / 1_048_576 / copy.wall))
        let delete = deleteRun(seed: 0, Interference())
        estimate["delete"] = delete.wall
        say(String(format: "RATE delete: %.0f files/s", Double(manifest.count) / delete.wall))
        let move = moveRun(seed: 0, Interference(), back: false)
        estimate["move"] = move.wall
        say(String(format: "RATE move (half merge, same volume): %.0f files/s", Double(manifest.count) / move.wall))
        let back = moveRun(seed: 0, Interference(), back: true)
        estimate["move-back"] = back.wall
        say(
            String(
                format: "RATE move back (a third merged, rest whole-folder renames): %.0f files/s",
                Double(manifest.count) / back.wall))
        offMain { removeQuickly(moved) }
    }
    baselineThreads = waitForThreads(atMost: 0, upTo: 6, onMain: true)
    say("threads at baseline (after calibration, settled 6 s): \(baselineThreads)")

    for seed in seedBase..<(seedBase + seedCount) {
        var random = Random(seed: UInt64(seed) &* 0x1234_5678_9ABC)
        HangGuard.shared.arm("seed \(seed)", seconds: 900)
        // Copy with interference, then delete what arrived with interference, then remove the rest.
        _ = copyRun(seed: seed, interference("copy", &random))
        let deleted = deleteRun(seed: seed, interference("delete", &random))
        if deleted.result.cancelled || !offMain({ topLevel(destination) }).isEmpty {
            let rest = deleteRun(seed: seed + 100_000, Interference(pauses: true))
            if rest.result.cancelled {
                findings.violation("delete: uninterrupted run reports cancelled", "seed \(seed)")
            }
        }
        // Move with interference, then move everything back (pauses only), which must restore the tree.
        _ = moveRun(seed: seed, interference("move", &random), back: false)
        var back = interference("move-back", &random)
        _ = moveRun(seed: seed, back, back: true)
        back = Interference(pauses: seed % 2 == 0)
        let restored = moveRun(seed: seed + 100_000, back, back: true)
        if restored.result.cancelled {
            findings.violation("move-back: uninterrupted run reports cancelled", "seed \(seed)")
        }
        MainWatchdog.shared.setPhase("verify (harness)")
        offMain {
            let state = survey(source)
            let bad = state.filter { $0 != 1 }.count
            if bad > 0 {
                findings.violation(
                    "tree not restored after moving back",
                    "seed \(seed): \(bad) files missing or different at the source")
            }
            let rest = walk(moved)
            if !rest.files.isEmpty {
                findings.violation(
                    "files left at the moved place after moving back",
                    "seed \(seed): \(rest.files.count), e.g. \(rest.files[0])")
            }
            removeQuickly(moved)
            removeQuickly(destination)
        }
        threadsAfter.append(threadCount())
        if (seed - seedBase + 1) % 10 == 0 || seed == seedBase + seedCount - 1 {
            MainWatchdog.shared.setPhase("settle (idle)")
            let settled = waitForThreads(atMost: baselineThreads, upTo: 8, onMain: true)
            say(
                "THREADS after seed \(seed): right after=\(threadsAfter.last!) settled(<=8s)=\(settled) baseline=\(baselineThreads) max so far=\(maxThreads) footprint=\(Int(footprintMB()))MB peakRSS=\(Int(peakRSSMB()))MB load=\(loadAverage())"
            )
            // (The system's queue threads come and go by a few; the program's own named threads must be gone.)
            if settled > baselineThreads + 2, threadCount(named: "AFM.", except: ".watch") > 0 {
                findings.violation(
                    "threads did not return to baseline",
                    "after seed \(seed): \(settled) vs \(baselineThreads): " + threadNames())
            }
        }
    }
    HangGuard.shared.disarm()
    for (kind, values) in durations.sorted(by: { $0.key < $1.key }) {
        say(
            String(
                format: "DURATIONS %@: n=%d min=%.2fs max=%.2fs mean=%.2fs", kind, values.count, values.min()!,
                values.max()!, values.reduce(0, +) / Double(values.count)))
    }
}

// MARK: A target that keeps writes back, with commits that fail at random

/// A MemoryFileSystem that claims `.deferredWrites`: it notes when each file was last written
/// (or renamed into place) and which of that a successful commit has covered.
final class DeferredTarget: FileSystemProvider {
    let base: MemoryFileSystem
    var scheme: String { base.scheme }
    var capabilities: FileSystemCapabilities { base.capabilities }
    private let lock = NSLock()
    private var sequence = 0
    private var written: [String: Int] = [:]
    private(set) var covered = 0
    private(set) var commitsOK = 0
    private(set) var commitsFailed = 0
    private var random: Random
    let failureRate: Int

    init(_ base: MemoryFileSystem, seed: UInt64, failureRate: Int) {
        self.base = base
        random = Random(seed: seed)
        self.failureRate = failureRate
    }

    func wrote(_ url: URL) {
        lock.lock()
        sequence += 1
        written[url.path] = sequence
        lock.unlock()
    }
    func writtenAt(_ path: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return written[path]
    }
    var counts: (ok: Int, failed: Int, covered: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (commitsOK, commitsFailed, covered)
    }

    private final class Writer: FileWriter {
        let inner: FileWriter, owner: DeferredTarget, url: URL
        init(_ inner: FileWriter, _ owner: DeferredTarget, _ url: URL) {
            (self.inner, self.owner, self.url) = (inner, owner, url)
        }
        func write(_ data: Data) throws { try inner.write(data) }
        func close(attributes: FileAttributes) throws {
            try inner.close(attributes: attributes)
            owner.wrote(url)
        }
        func interrupt() { inner.interrupt() }
    }

    func capabilities(for url: URL) -> FileSystemCapabilities { base.capabilities(for: url) }
    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden)
    }
    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        try base.list(directory, showHidden: showHidden, cancellation: cancellation)
    }
    func item(at url: URL) -> FileItem? { base.item(at: url) }
    func parent(of directory: URL) -> URL? { base.parent(of: directory) }
    func read(_ url: URL) throws -> FileReader { try base.read(url) }
    func read(_ url: URL, cancellation: CancellationFlag) throws -> FileReader {
        try base.read(url, cancellation: cancellation)
    }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func write(_ url: URL) throws -> FileWriter { Writer(try base.write(url), self, url) }
    func write(_ url: URL, cancellation: CancellationFlag) throws -> FileWriter {
        Writer(try base.write(url, cancellation: cancellation), self, url)
    }
    func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> FileWriter {
        Writer(try base.append(to: url, at: offset, cancellation: cancellation), self, url)
    }
    func remove(_ url: URL) throws { try base.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try base.move(source, to: destination, replacing: replacing)
        // A rename is a change that waits for a commit like any other.
        lock.lock()
        sequence += 1
        written[source.path] = nil
        written[destination.path] = sequence
        lock.unlock()
    }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try base.copy(source, to: destination, progress: progress)
        wrote(destination)
    }
    func copyMetadata(from source: URL, to destination: URL) throws {
        try base.copyMetadata(from: source, to: destination)
    }
    func commit(_ url: URL, cancellation: CancellationFlag) throws {
        lock.lock()
        let fails = Int.random(in: 0..<100, using: &random) < failureRate
        if fails {
            commitsFailed += 1
        } else {
            commitsOK += 1
            covered = sequence
        }
        lock.unlock()
        try base.commit(url, cancellation: cancellation)
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
    }
    func quarantine(of url: URL) -> Data? { base.quarantine(of: url) }
    func setQuarantine(_ value: Data, of url: URL) throws { try base.setQuarantine(value, of: url) }
    func displayPath(_ url: URL) -> String { base.displayPath(url) }
    func location(from text: String) -> URL? { base.location(from: text) }
    func volume(of url: URL) -> VolumeInfo? { base.volume(of: url) }
}

if memSeeds > 0 {
    let memFiles = argument("--memfiles", 3_000)
    let memFolders = argument("--memfolders", 60)
    let perFolder = max(1, memFiles / memFolders)
    let entries =
        (0..<memFiles).map {
            Entry(
                path: String(format: "m%03d/g%05d.dat", min(memFolders - 1, $0 / perFolder), $0), index: 900_000 + $0,
                size: 8 + ($0 &* 131) % 1_500)
        }
        + (0..<3).map { Entry(path: "top\($0).bin", index: 990_000 + $0, size: 300_000 + $0 * 4_096) }
    let memSource = root.appendingPathComponent("memsrc")
    step("deferred: build source tree") {
        offMain {
            removeQuickly(memSource)
            try! fm.createDirectory(at: memSource, withIntermediateDirectories: true)
            buildTree(at: memSource, entries: entries)
        }
    }
    var totals = (runs: 0, cancelled: 0, commitsOK: 0, commitsFailed: 0, removed: 0, kept: 0)
    for seed in seedBase..<(seedBase + memSeeds) {
        var random = Random(seed: UInt64(seed) &* 0xABCDEF &+ 99)
        let memory = MemoryFileSystem(scheme: "dst")
        memory.capabilities = [.write, .deferredWrites]
        memory.addDirectory("/out")
        let failureRate = [0, 20, 50, 100][Int.random(in: 0..<4, using: &random)]
        let target = DeferredTarget(memory, seed: UInt64(seed), failureRate: failureRate)
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        registry.register(target)
        let batch = [7, 40, 250, 10_000][Int.random(in: 0..<4, using: &random)]
        var plan = Interference()
        if Int.random(in: 0..<10, using: &random) < 4 {
            plan.cancelAfter = Double.random(in: 0...0.6, using: &random)
        }
        plan.pauses = Bool.random(using: &random)
        plan.cancelsOffMain = Bool.random(using: &random)
        let errorAnswer: ErrorChoice = [.skip, .skipAll, .abort, .retry][Int.random(in: 0..<4, using: &random)]
        MainWatchdog.shared.setPhase("deferred move")
        let sources = topLevel(memSource)
        let retried = Box(0)
        let outcome = runJob(
            "deferred#\(seed)", seed: UInt64(seed), interference: plan, limit: 120,
            configure: { job in
                job.deferredBatchSize = batch
                if let recorder = job.delegate as? Recorder {
                    // Retry would ask for ever; it is answered a few times and then becomes Skip.
                    recorder.errorAnswer = errorAnswer
                    if errorAnswer == .retry {
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                            recorder.errorAnswer = .skip
                            retried.value += 1
                        }
                    }
                }
            },
            make: { flag in
                let job = FileJob(
                    kind: .move, sources: sources, target: TargetSpec(directory: memory.url("/out")),
                    fileSystems: registry, cancellation: flag)
                job.options.overwrite = .overwriteAll
                return job
            })
        let counts = target.counts
        MainWatchdog.shared.setPhase("verify (harness)")
        let (removed, kept): (Int, Int) = offMain {
            let state = survey(memSource, entries: entries)
            var removed = 0
            var kept = 0
            for (index, entry) in entries.enumerated() {
                let path = "/out/" + entry.path
                let expected = bytes(index: entry.index, size: entry.size)
                let reader = try? memory.read(memory.url(path))
                var arrived: Data?
                if let reader {
                    var all = Data()
                    while let block = try? reader.read(upToCount: 1 << 20) { all.append(block) }
                    reader.close()
                    arrived = all
                }
                if state[index] == 2 { findings.violation("deferred: source damaged", "seed \(seed): \(entry.path)") }
                if state[index] == 0 {
                    removed += 1
                    if arrived == nil {
                        findings.violation(
                            "deferred: FILE LOST (source removed, nothing at target)",
                            "seed \(seed) rate=\(failureRate) batch=\(batch): \(entry.path)")
                    } else if arrived != expected {
                        findings.violation(
                            "deferred: source removed, target content differs", "seed \(seed): \(entry.path)")
                    } else if let at = target.writtenAt(path), at > counts.covered {
                        findings.violation(
                            "deferred: SOURCE REMOVED WITHOUT A SUCCESSFUL COMMIT covering its write",
                            "seed \(seed) rate=\(failureRate)% batch=\(batch) commits ok/failed=\(counts.ok)/\(counts.failed): \(entry.path) written at \(at), last good commit covers \(counts.covered)"
                        )
                    } else if target.writtenAt(path) == nil {
                        findings.violation(
                            "deferred: source removed, target write not seen by the harness",
                            "seed \(seed): \(entry.path)")
                    }
                } else {
                    kept += 1
                }
            }
            if counts.ok == 0, removed > 0 {
                findings.violation(
                    "deferred: sources removed although no commit succeeded", "seed \(seed): \(removed)")
            }
            if !outcome.result.cancelled, counts.failed == 0, kept > 0 {
                findings.violation(
                    "deferred: finished, every commit succeeded, but sources remain", "seed \(seed): \(kept)")
            }
            for path in memory.allPaths where isTemporary(path) {
                findings.violation("deferred: temporary file left at target", "seed \(seed): \(path)")
            }
            for path in walk(memSource).files where isTemporary(path) {
                findings.violation("deferred: temporary file left at source", "seed \(seed): \(path)")
            }
            // The next seed starts from the whole tree again.
            let missing = entries.indices.filter { state[$0] != 1 }.map { entries[$0] }
            buildTree(at: memSource, entries: missing)
            return (removed, kept)
        }
        say(
            describe("deferred-move", seed, outcome, plan)
                + " rate=\(failureRate)% batch=\(batch) answer=\(errorAnswer) commits ok/failed=\(counts.ok)/\(counts.failed) removed=\(removed) kept=\(kept) errorsAsked=\(outcome.errors.count)"
        )
        totals.runs += 1
        totals.cancelled += outcome.result.cancelled ? 1 : 0
        totals.commitsOK += counts.ok
        totals.commitsFailed += counts.failed
        totals.removed += removed
        totals.kept += kept
    }
    say(
        "DEFERRED TOTAL runs=\(totals.runs) cancelled=\(totals.cancelled) commits ok=\(totals.commitsOK) failed=\(totals.commitsFailed) sources removed=\(totals.removed) kept=\(totals.kept)"
    )
    MainWatchdog.shared.setPhase("settle (idle)")
    let settled = waitForThreads(atMost: baselineThreads, upTo: 8, onMain: true)
    say("THREADS after deferred runs: settled=\(settled) baseline(local)=\(baselineThreads)")
    if !keepTree { offMain { removeQuickly(memSource) } }
}

if !keepTree, !skipLocal {
    step("remove tree") {
        offMain {
            removeQuickly(source)
            removeQuickly(destination)
            removeQuickly(moved)
        }
    }
}
MainWatchdog.shared.setPhase("end")
findings.summary()
MainWatchdog.shared.report(title: "StressJobs")
say(
    String(
        format: "FINAL threads=%d (baseline %d, max seen %d) peakRSS=%.0fMB footprint=%.0fMB load=%.1f", threadCount(),
        baselineThreads, maxThreads, peakRSSMB(), footprintMB(), loadAverage()))
exit(findings.violations.isEmpty ? 0 : 3)
