import AFMKernel
import AppKit
@testable import FindFilesPlugin
import Foundation
import LocalFileSystemPlugin
import StressKit
import TestSupport

// Scenario 6: the Find Files engine and its window controller (headless, never shown).
//
//   StressFind gen <tree>                                   builds the nested tree
//   StressFind run <tree> <million|-> <resultsDir> <cancels> [seed]
//
// The engine is driven both directly (FileSearch.run on a background thread) and through the
// real FindFilesWindowController (prepare/startSearch/cancelSearch), whose own batching hands
// the results to the main queue.

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { say("usage"); exit(2) }
let fm = FileManager.default
let needle = "NEEDLE_XYZ"

// MARK: Generation

func generate(_ root: URL) {
    let line = "The quick brown fox jumps over the lazy dog; pack my box with five dozen liquor jugs.\n"
    let body = String(repeating: line, count: 4)
    DispatchQueue.concurrentPerform(iterations: 2000) { folder in
        let (a, b, c) = (folder / 100, (folder / 10) % 10, folder % 10)
        let directory = root.appendingPathComponent(String(format: "d%02d/e%d/f%d", a, b, c))
        try! fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in 0..<50 {
            let global = folder * 50 + file
            let isText = file < 40
            let name = String(format: isText ? "n%02d-%06d.txt" : "b%02d-%06d.dat", file, global)
            var text = "file \(global)\n" + body
            if global % 97 == 0 { text += "here is the \(needle) of file \(global)\n" }
            if global % 1013 == 0 { text += "lowercase needle_xyz too\n" }
            try! Data(text.utf8).write(to: directory.appendingPathComponent(name))
        }
    }
    // Two large files, so a text search is in the middle of a long read when it is cancelled.
    let big = root.appendingPathComponent("big")
    try! fm.createDirectory(at: big, withIntermediateDirectories: true)
    var random = Random(seed: 7)
    var block = Data(count: 1 << 20)
    block.withUnsafeMutableBytes { raw in
        let words = raw.bindMemory(to: UInt64.self)
        for index in words.indices { words[index] = random.next() }
    }
    for index in 0..<2 {
        let url = big.appendingPathComponent("big\(index).bin")
        fm.createFile(atPath: url.path, contents: nil)
        let handle = try! FileHandle(forWritingTo: url)
        for _ in 0..<256 { handle.write(block) }
        if index == 1 { handle.write(Data("tail \(needle) tail".utf8)) }
        try! handle.close()
    }
}

if arguments[1] == "gen" {
    let t = now()
    generate(URL(fileURLWithPath: arguments[2]))
    say(String(format: "generated in %.1fs", now() - t))
    exit(0)
}

guard arguments.count >= 6 else { say("usage"); exit(2) }
let tree = URL(fileURLWithPath: arguments[2], isDirectory: true)
let million: URL? = arguments[3] == "-" ? nil : URL(fileURLWithPath: arguments[3], isDirectory: true)
let resultsDirectory = arguments[4]
let cancels = Int(arguments[5])!
let seed = arguments.count > 6 ? UInt64(arguments[6])! : 1

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
MainWatchdog.shared.start()
HangGuard.shared.sampleDirectory = resultsDirectory
var failures: [String] = []
func fail(_ text: String) {
    failures.append(text)
    say("FAIL: " + text)
}

// MARK: Ground truth, found without the program's code

struct Truth {
    var names: Set<String> = []
    var text: Set<String> = []
}

/// Every regular file below `root` (readdir), in parallel per top-level folder.
func allFiles(_ root: URL) -> [String] {
    var result: [String] = []
    var stack = [root.path]
    while let directory = stack.popLast() {
        guard let handle = opendir(directory) else { continue }
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if name == "." || name == ".." || name.hasPrefix(".") { continue }
            let path = directory + "/" + name
            if entry.pointee.d_type == DT_DIR { stack.append(path) } else { result.append(path) }
        }
        closedir(handle)
    }
    return result
}

func contains(_ path: String, _ pattern: [UInt8], caseInsensitive: Bool) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    if info.st_size > 1 << 24 {
        // Large files are not mapped (that would count as this process's memory): `grep` reads them.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-qai", String(decoding: pattern, as: UTF8.self), path]
        try! process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= pattern.count else { return false }
    let lower = pattern.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        let bytes = raw.bindMemory(to: UInt8.self)
        let last = bytes.count - lower.count
        var index = 0
        let first = lower[0]
        while index <= last {
            var byte = bytes[index]
            if caseInsensitive, byte >= 65, byte <= 90 { byte += 32 }
            if byte == first {
                var offset = 1
                while offset < lower.count {
                    var other = bytes[index + offset]
                    if caseInsensitive, other >= 65, other <= 90 { other += 32 }
                    if other != lower[offset] { break }
                    offset += 1
                }
                if offset == lower.count { return true }
            }
            index += 1
        }
        return false
    }
}

func parallelFilter(_ paths: [String], _ test: @escaping (String) -> Bool) -> Set<String> {
    let lock = NSLock()
    var found = Set<String>()
    let chunk = max(1, paths.count / 64)
    DispatchQueue.concurrentPerform(iterations: (paths.count + chunk - 1) / chunk) { part in
        var own: [String] = []
        for path in paths[(part * chunk)..<min(paths.count, (part + 1) * chunk)] where test(path) { own.append(path) }
        lock.lock(); found.formUnion(own); lock.unlock()
    }
    return found
}

// MARK: The searches

struct Case {
    let label: String
    let directory: URL
    let names: String
    let text: String
    var expected: Set<String>
}

var cases: [Case] = []
step("ground truth: tree") {
    let files = allFiles(tree)
    say("tree: \(files.count) files")
    let txt = Set(files.filter { $0.hasSuffix(".txt") })
    // The search is not case sensitive by default.
    let withNeedle = parallelFilter(files) { contains($0, Array(needle.utf8), caseInsensitive: true) }
    cases.append(Case(label: "tree name *.txt", directory: tree, names: "*.txt", text: "", expected: txt))
    cases.append(Case(label: "tree text NEEDLE", directory: tree, names: "", text: needle, expected: withNeedle))
    say("tree: *.txt \(txt.count), with needle \(withNeedle.count)")
}
if let million {
    step("ground truth: million") {
        let files = allFiles(million)
        say("million: \(files.count) files")
        let png = Set(files.filter { $0.hasSuffix("7.png") })
        let nonEmpty = files.filter { path in
            var info = stat()
            return lstat(path, &info) == 0 && info.st_size >= 4
        }
        let withText = parallelFilter(nonEmpty) { contains($0, Array("xxxx".utf8), caseInsensitive: true) }
        cases.append(Case(label: "million name *7.png", directory: million, names: "*7.png", text: "", expected: png))
        cases.append(Case(label: "million text xxxx", directory: million, names: "", text: "xxxx", expected: withText))
        cases.append(Case(label: "million name * (all)", directory: million, names: "", text: "", expected: Set(files)))
        say("million: *7.png \(png.count), with xxxx \(withText.count), all files \(files.count)")
    }
}

let memory = MemoryFileSystem()
memory.addFile("/A/one.txt", "x")
let plugin = FindFilesPlugin()
let bench = TestBench(plugins: [plugin], fileSystems: [LocalFileSystem(), memory], left: memory.url("/A"), right: memory.url("/A"))
let fileSystems = bench.kernel.fileSystems

func verify(_ label: String, _ items: [FileItem], against expected: Set<String>, filesOnly: Bool) {
    MainWatchdog.shared.setPhase("(harness: checking results)")
    // "all" also finds the folders; the truth lists files.
    let paths = items.filter { !filesOnly || !$0.isDirectory }.map { $0.url.path }
    let unique = Set(paths)
    if unique.count != paths.count { fail("\(label): \(paths.count - unique.count) duplicate results") }
    if unique != expected {
        let missing = expected.subtracting(unique), extra = unique.subtracting(expected)
        fail("\(label): expected \(expected.count), got \(unique.count); missing \(missing.count) e.g. \(missing.prefix(2)), extra \(extra.count) e.g. \(extra.prefix(2))")
    }
}

func heapLine(_ label: String) {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    say("HEAP " + pad(label, 44) + String(format: " footprint %6.0f MB; malloc in use %6.0f MB, allocated from the system %6.0f MB; threads %d", footprintMB(),
               Double(stats.size_in_use) / 1_048_576, Double(stats.size_allocated) / 1_048_576, threadCount()))
}

// MARK: 1. The engine alone

step("idle baseline") { pump(for: 2) }
let baselineThreads = threadCount()
say("threads at baseline: \(baselineThreads)")

func runEngine(_ test: Case) -> (items: [FileItem], seconds: Double, first: Double) {
    let search = FileSearch(SearchQuery(directory: test.directory, names: test.names, text: test.text), fileSystems: fileSystems)
    var items: [FileItem] = []
    var first = -1.0
    var done = false
    let started = now()
    DispatchQueue.global(qos: .userInitiated).async {
        var own: [FileItem] = []
        var firstAt = -1.0
        search.run { item in
            if own.isEmpty { firstAt = now() - started }
            own.append(item)
        }
        DispatchQueue.main.async { (items, first, done) = (own, firstAt, true) }
    }
    pump(upTo: 900) { done }
    return (items, now() - started, first)
}

var engineOrders: [String: [String]] = [:]
for test in cases {
    for round in 0..<2 {
        step("engine: \(test.label) #\(round)", limit: 900) {
            let (items, seconds, first) = runEngine(test)
            say(String(format: "  engine %@: %d results in %.3fs, first after %.3fs", test.label, items.count, seconds, first))
            verify("engine " + test.label, items, against: test.expected, filesOnly: true)
            let order = test.expected.count > 200_000 ? [] : items.map { $0.url.path }
            if let before = engineOrders[test.label], before != order { fail("engine \(test.label): two runs gave a different order") }
            engineOrders[test.label] = order
        }
    }
}
engineOrders = [:]

// Eight searches of the tree at once, each from a thread of its own.
step("engine: 8 concurrent searches of the tree", limit: 600) {
    let lock = NSLock()
    var outcomes: [(Int, [FileItem])] = []
    let group = DispatchGroup()
    for index in 0..<8 {
        group.enter()
        Thread.detachNewThread {
            let test = cases[index % 2]
            let search = FileSearch(SearchQuery(directory: test.directory, names: test.names, text: test.text), fileSystems: fileSystems)
            var own: [FileItem] = []
            search.run { own.append($0) }
            lock.lock(); outcomes.append((index % 2, own)); lock.unlock()
            group.leave()
        }
    }
    var finished = false
    group.notify(queue: .main) { finished = true }
    pump(upTo: 600) { finished }
    for (which, items) in outcomes { verify("concurrent " + cases[which].label, items, against: cases[which].expected, filesOnly: true) }
}
heapLine("after the engine runs")
step("threads settle after engine runs") {
    let after = waitForThreads(atMost: baselineThreads + 2, upTo: 10, onMain: true)
    say("threads after engine runs: \(after) (baseline \(baselineThreads))")
}

// MARK: 2. Through the window controller

let window = plugin.mainWindow(in: bench.kernel)
var finishedCount = 0
window.onFinished = { finishedCount += 1 }

func startThroughWindow(_ test: Case) {
    window.prepare(startingIn: test.directory, includeHidden: false)
    var settings = window.form.settings
    settings.searchFor = test.names
    settings.findText = !test.text.isEmpty
    settings.text = test.text
    settings.useSpotlight = false
    window.form.settings = settings
    window.startSearch()
}

var typical: [String: Double] = [:]
for test in cases {
    step("window: \(test.label)", limit: 900) {
        let before = finishedCount
        let started = now()
        startThroughWindow(test)
        var first = -1.0
        pump(upTo: 900) {
            if first < 0, window.numberOfRows(in: NSTableView()) > 1 { first = now() - started }
            return finishedCount > before
        }
        let seconds = now() - started
        typical[test.label] = seconds
        pump(for: 0.3)
        MainWatchdog.shared.setPhase("(harness: checking results)")
        let items = window.resultItems
        say(String(format: "  window %@: %d results in %.3fs, first rows after %.3fs, threads %d", test.label, items.count, seconds, first, threadCount()))
        verify("window " + test.label, items, against: test.expected, filesOnly: true)
        pump(for: 0.3)
    }
}

// MARK: 3. Cancelled at random moments

var random = Random(seed: seed)
var cancelLatencies: [Double] = []
var worstCancel = (0.0, "")
var threadsAfter: [Int] = []
var completedInstead = 0
step("window: \(cancels) searches cancelled at random", limit: Double(cancels) * 30 + 60) {
    for round in 0..<cancels {
        let test = cases[Int(random.next() % UInt64(cases.count))]
        let usual = typical[test.label] ?? 1
        // Anywhere from at once to a little past the usual end.
        let delay = Double(random.next() % 1000) / 1000 * usual * 1.1
        let before = finishedCount
        startThroughWindow(test)
        pump(upTo: delay) { finishedCount > before }
        if finishedCount > before {
            completedInstead += 1
            let phase = "window: \(cancels) searches cancelled at random"
            defer { MainWatchdog.shared.setPhase(phase) }
            verify("uncancelled in torture: " + test.label, window.resultItems, against: test.expected, filesOnly: true)
        } else {
            let asked = now()
            window.cancelSearch()
            if !pump(upTo: 30, until: { finishedCount > before }) {
                fail("round \(round) \(test.label): a cancelled search did not end within 30 s (cancelled after \(delay)s)")
                HangGuard.shared.arm("cancelled search does not end", seconds: 0)
                pump(for: 600)
            }
            let latency = now() - asked
            cancelLatencies.append(latency)
            if latency > worstCancel.0 { worstCancel = (latency, String(format: "%@ cancelled after %.3fs", test.label, delay)) }
            // What a cancelled search shows must still be a duplicate-free part of the truth.
            MainWatchdog.shared.setPhase("(harness: checking results)")
            defer { MainWatchdog.shared.setPhase("window: \(cancels) searches cancelled at random") }
            let paths = window.resultItems.filter { !$0.isDirectory }.map { $0.url.path }
            if Set(paths).count != paths.count { fail("round \(round) \(test.label): duplicates in a cancelled search's results") }
            if !Set(paths).isSubset(of: test.expected) { fail("round \(round) \(test.label): a cancelled search lists files that do not match") }
        }
        // The next search starts right away half of the time, as a user retyping would.
        if random.next() % 2 == 0 { pump(for: 0.02) }
        threadsAfter.append(threadCount())
    }
}
let sorted = cancelLatencies.sorted()
if !sorted.isEmpty {
    say(String(format: "cancel -> finished: n=%d median=%.1fms p95=%.1fms max=%.1fms (%@); %d ended before the cancel",
               sorted.count, sorted[sorted.count / 2] * 1000, sorted[Int(Double(sorted.count) * 0.95)] * 1000, sorted.last! * 1000, worstCancel.1, completedInstead))
    say("threads right after each round: min \(threadsAfter.min()!) max \(threadsAfter.max()!) last \(threadsAfter.last!)")
}

heapLine("after the window's cancelled searches")
// The same on the engine alone, cancelled from another thread; `run` must return.
var engineReturn: [Double] = []
step("engine: \(cancels) runs cancelled from another thread", limit: Double(cancels) * 30 + 60) {
    for round in 0..<cancels {
        let test = cases[Int(random.next() % UInt64(cases.count))]
        let delay = Double(random.next() % 1000) / 1000 * (typical[test.label] ?? 1)
        let search = FileSearch(SearchQuery(directory: test.directory, names: test.names, text: test.text), fileSystems: fileSystems)
        var returned = false
        var returnedAt = 0.0
        var count = 0
        DispatchQueue.global(qos: .userInitiated).async {
            var own = 0
            search.run { _ in own += 1 }
            let at = now()
            DispatchQueue.main.async { (returned, returnedAt, count) = (true, at, own) }
        }
        let canceller = Thread {
            usleep(UInt32(delay * 1_000_000))
            search.cancel()
        }
        let started = now()
        canceller.start()
        if !pump(upTo: delay + 30, until: { returned }) {
            fail("engine round \(round) \(test.label): run() did not return within 30 s of the cancel")
            HangGuard.shared.arm("engine run does not return", seconds: 0)
            pump(for: 600)
        }
        engineReturn.append(max(0, returnedAt - started - delay))
        _ = count
    }
}
let returns = engineReturn.sorted()
if !returns.isEmpty {
    say(String(format: "engine cancel -> run returned: median=%.1fms p95=%.1fms max=%.1fms", returns[returns.count / 2] * 1000, returns[Int(Double(returns.count) * 0.95)] * 1000, returns.last! * 1000))
}

heapLine("after the engine's cancelled runs")
step("threads settle at the end") {
    var trace: [String] = []
    let started = now()
    for _ in 0..<60 {
        trace.append(String(format: "%.1fs:%d", now() - started, threadCount()))
        if threadCount() <= baselineThreads + 2 { break }
        pump(for: 0.5)
    }
    say("threads over time after the last search: " + trace.joined(separator: " "))
    let end = threadCount()
    say("threads: baseline \(baselineThreads), at the end \(end)")
    if end > baselineThreads + 4 { fail("thread count did not return to the baseline: \(baselineThreads) -> \(end)") }
}

// After everything, an uncancelled search must still be complete.
for test in cases.prefix(2) {
    step("window after torture: \(test.label)", limit: 900) {
        let before = finishedCount
        startThroughWindow(test)
        pump(upTo: 900) { finishedCount > before }
        pump(for: 0.3)
        verify("after torture " + test.label, window.resultItems, against: test.expected, filesOnly: true)
    }
}

heapLine("at the end")
if ProcessInfo.processInfo.environment["STRESS_TEXT_LOOP"] != nil {
    // Twenty uncancelled text searches of the tree in a row: does each one add memory?
    for round in 0..<20 {
        _ = runEngine(cases[1])
        if round % 5 == 4 { heapLine("after \(round + 1) more text searches of the tree") }
    }
    pump(for: 5)
    heapLine("5 s after the last of them")
}
MainWatchdog.shared.report(title: "scenario 6, Find Files")
say("\nFAILURES: \(failures.count)")
for failure in failures.prefix(40) { say("  " + failure) }
say(String(format: "peak RSS %.0f MB, threads %d, load %.1f", peakRSSMB(), threadCount(), loadAverage()))
exit(failures.isEmpty ? 0 : 1)
