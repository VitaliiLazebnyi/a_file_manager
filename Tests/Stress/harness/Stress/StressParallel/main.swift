import AFMKernel
import Darwin
import Foundation
import StressKit

// Scenario 3: Parallel.map torture. `StressParallel` runs everything; `StressParallel child <case>`
// runs one of the cases that are expected to deadlock or crash, for the parent to watch.

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments
let resultsDirectory = ProcessInfo.processInfo.environment["STRESS_RESULTS"] ?? FileManager.default.currentDirectoryPath
HangGuard.shared.sampleDirectory = resultsDirectory

/// Highest thread count seen while it runs.
final class ThreadPeak {
    private var peak = 0
    private var running = true
    private let lock = NSLock()
    init() {
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let go = running
                lock.unlock()
                if !go { return }
                let count = threadCount()
                lock.lock()
                peak = max(peak, count)
                lock.unlock()
                usleep(5_000)
            }
        }
        thread.start()
    }
    func stop() -> Int {
        lock.lock()
        running = false
        let value = peak
        lock.unlock()
        return value
    }
}

func mix(_ value: UInt64) -> UInt64 {
    var z = value &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

/// Runs `body` on a background thread while the main thread pumps its run loop; false on timeout.
func inBackground(upTo seconds: Double, _ body: @escaping () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    var finished = false
    let thread = Thread {
        body()
        done.signal()
    }
    thread.stackSize = 8 << 20
    thread.start()
    return pump(upTo: seconds) {
        if !finished, done.wait(timeout: .now()) == .success { finished = true }
        return finished
    }
}

// MARK: Nested tree

struct Behaviour {
    var sleeps = true
    var io = true
    var mainSync = false
}
let mainSyncs = ManagedAtomicCounter()

final class ManagedAtomicCounter {
    private var value = 0
    private let lock = NSLock()
    func add(_ n: Int = 1) {
        lock.lock()
        value += n
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// What the tree below `path` adds up to, computed without `Parallel`.
func expected(depth: Int, width: Int, path: UInt64) -> UInt64 {
    if depth == 0 { return mix(path) & 0xFFFF }
    var sum: UInt64 = 0
    for index in 0..<width { sum &+= expected(depth: depth - 1, width: width, path: mix(path &* 31 &+ UInt64(index))) }
    return sum &+ (mix(path) & 0xFF)
}

func tree(depth: Int, width: Int, path: UInt64, _ behaviour: Behaviour) -> UInt64 {
    if depth == 0 {
        let kind = mix(path ^ 0xABCD) % 100
        if behaviour.sleeps, kind < 4 { usleep(useconds_t(500 + mix(path) % 3_000)) }
        if behaviour.io, kind >= 4, kind < 10 {
            var info = stat()
            _ = stat("/usr/lib", &info)
        }
        if behaviour.mainSync, kind >= 10, kind < 11, !Thread.isMainThread {
            DispatchQueue.main.sync { mainSyncs.add() }
        }
        return mix(path) & 0xFFFF
    }
    let children = (0..<width).map { mix(path &* 31 &+ UInt64($0)) }
    let parts = Parallel.map(children) { tree(depth: depth - 1, width: width, path: $0, behaviour) }
    // The order of the results must be the order of the input.
    return parts.reduce(0, &+) &+ (mix(path) & 0xFF)
}

// MARK: Cases expected to deadlock or crash, run in a child process

if arguments.count >= 3, arguments[1] == "child" {
    switch arguments[2] {
    case "main-in-map-bodies-sync-to-main":
        // The main thread is inside Parallel.map; bodies on helper threads call DispatchQueue.main.sync.
        say("child: main thread calls Parallel.map; helper-thread bodies call DispatchQueue.main.sync")
        let result = Parallel.map(Array(0..<64)) { (value: Int) -> Int in
            if !Thread.isMainThread { DispatchQueue.main.sync { mainSyncs.add() } }
            return value * 2
        }
        say("child: returned, ordered=\(result == (0..<64).map { $0 * 2 }) mainSyncs=\(mainSyncs.count)")
        exit(0)

    case "main-in-map-all-bodies-sync-to-main":
        say("child: main thread calls Parallel.map; every body (also on main) calls DispatchQueue.main.sync")
        let result = Parallel.map(Array(0..<64)) { (value: Int) -> Int in
            DispatchQueue.main.sync { mainSyncs.add() }
            return value * 2
        }
        say("child: returned \(result.count)")
        exit(0)

    default:
        exit(2)
    }
}

/// Runs a child case; reports whether it ended, crashed or hung (then samples and kills it).
func runChild(_ name: String, patience: Double) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["child", name]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    let deadline = now() + patience
    while process.isRunning, now() < deadline { usleep(50_000) }
    if process.isRunning {
        let file = resultsDirectory + "/parallel-child-\(name).sample.txt"
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = ["\(process.processIdentifier)", "2", "-file", file]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        try? sample.run()
        sample.waitUntilExit()
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        say("CHILD \(name): DEADLOCK (no exit within \(patience)s); sample in \(file)")
    } else {
        say(
            "CHILD \(name): exited status=\(process.terminationStatus) reason=\(process.terminationReason == .uncaughtSignal ? "signal" : "exit")"
        )
    }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for line in output.split(separator: "\n").prefix(12) { say("   | " + line) }
}

// MARK: The run

MainWatchdog.shared.start()
let baseline = step("0 idle baseline (1 s)") {
    pump(for: 1)
    return threadCount()
}
say("   threads by name at baseline: " + threadNames())
say("cores=\(ProcessInfo.processInfo.activeProcessorCount) baseline threads=\(baseline)")
var failures: [String] = []
func check(_ ok: Bool, _ what: String) {
    if !ok {
        failures.append(what)
        say("FAIL: " + what)
    }
}

// 1. 10,000 small maps from 32 threads at once.
step("1 10,000 small maps from 32 threads", limit: 120) {
    let peak = ThreadPeak()
    let wrong = ManagedAtomicCounter()
    let ok = inBackground(upTo: 110) {
        let group = DispatchGroup()
        for thread in 0..<32 {
            group.enter()
            let worker = Thread {
                var random = Random(seed: UInt64(thread))
                for round in 0..<313 {
                    let count = Int.random(in: 2...64, using: &random)
                    let seed = thread * 1_000 + round
                    let input = (0..<count).map { $0 &+ seed }
                    let output = Parallel.map(input) { $0 &* 3 &+ 1 }
                    if output != input.map({ $0 &* 3 &+ 1 }) { wrong.add() }
                }
                group.leave()
            }
            worker.start()
        }
        group.wait()
    }
    check(ok, "1: 10,016 small maps did not finish in 110 s")
    check(wrong.count == 0, "1: \(wrong.count) maps returned wrong or misordered results")
    say("   maps=10016 wrong=\(wrong.count) peak threads=\(peak.stop()) (32 callers + pool limit \(15 * 4) + harness)")
}

// 2. Nested maps, depth 4 x width 16, with bodies that sleep and do I/O, from a background thread.
let want4 = expected(depth: 4, width: 16, path: 1)
step("2 nested depth 4 x width 16 (sleep, I/O)", limit: 180) {
    let peak = ThreadPeak()
    var got: UInt64 = 0
    let ok = inBackground(upTo: 170) { got = tree(depth: 4, width: 16, path: 1, Behaviour()) }
    check(ok, "2: nested map did not finish in 170 s")
    check(got == want4, "2: nested map returned \(got), expected \(want4)")
    say("   leaves=65536 correct=\(got == want4) peak threads=\(peak.stop())")
}

// 3. The same from 4 threads at once, with bodies that also hop to the main thread, while the
//    main thread itself keeps calling Parallel.map between turns of its run loop.
step("3 nested x4 roots + main.sync hops + main in map", limit: 240) {
    let peak = ThreadPeak()
    var results = [UInt64](repeating: 0, count: 4)
    let lock = NSLock()
    var finishedRoots = 0
    for root in 0..<4 {
        let thread = Thread {
            let value = tree(
                depth: 4, width: 16, path: UInt64(root + 1), Behaviour(sleeps: true, io: true, mainSync: true))
            lock.lock()
            results[root] = value
            finishedRoots += 1
            lock.unlock()
        }
        thread.stackSize = 8 << 20
        thread.start()
    }
    var mainMaps = 0
    var mainWrong = 0
    let ok = pump(upTo: 220) {
        // The main thread's own map, between turns of the run loop.
        let input = Array(0..<200)
        let output = Parallel.map(input) { mix(UInt64($0)) }
        if output != input.map({ mix(UInt64($0)) }) { mainWrong += 1 }
        mainMaps += 1
        lock.lock()
        defer { lock.unlock() }
        return finishedRoots == 4
    }
    check(ok, "3: nested maps with main.sync hops did not finish in 220 s (deadlock?)")
    for root in 0..<4 {
        let want = expected(depth: 4, width: 16, path: UInt64(root + 1))
        check(results[root] == want, "3: root \(root) returned \(results[root]), expected \(want)")
    }
    check(mainWrong == 0, "3: \(mainWrong) main-thread maps wrong")
    say(
        "   roots=4 leaves=262144 mainSync hops=\(mainSyncs.count) main-thread maps=\(mainMaps) peak threads=\(peak.stop())"
    )
}

// 4. Nested map called on the main thread itself (the UI thread is blocked for its length by design).
step("4 nested depth 3 x 16 ON the main thread", limit: 120) {
    let got = tree(depth: 3, width: 16, path: 7, Behaviour(sleeps: true, io: true, mainSync: false))
    check(got == expected(depth: 3, width: 16, path: 7), "4: wrong result on main thread")
}

// 5. Bodies that only wait: does the pool grow, and how far.
step("5 256 bodies that each sleep 100 ms", limit: 120) {
    let peak = ThreadPeak()
    let started = now()
    var out: [Int] = []
    let ok = inBackground(upTo: 110) {
        out = Parallel.map(Array(0..<256)) {
            usleep(100_000)
            return $0
        }
    }
    check(ok && out == Array(0..<256), "5: sleeping bodies wrong or late")
    say(
        String(
            format: "   wall=%.2fs (serial would be 25.6 s; 16 threads 1.6 s; 60 threads 0.43 s) peak threads=%d",
            now() - started, peak.stop()))
}

// 6. Bursts separated by the pool's idle time (2 s), so helper threads leave while new jobs open.
step("6 bursts around the 2 s thread retirement", limit: 180) {
    let wrongCount = ManagedAtomicCounter()
    let ok = inBackground(upTo: 170) {
        var random = Random(seed: 99)
        for round in 0..<12 {
            let group = DispatchGroup()
            for caller in 0..<8 {
                group.enter()
                let thread = Thread {
                    for inner in 0..<50 {
                        let input = Array(0..<(40 + inner))
                        if Parallel.map(input, { $0 + caller }) != input.map({ $0 + caller }) { wrongCount.add() }
                    }
                    group.leave()
                }
                thread.start()
            }
            group.wait()
            // Sleep to just around the moment the helpers give up waiting.
            usleep(useconds_t(1_990_000 + Int.random(in: 0...20_000, using: &random)))
            _ = round
        }
    }
    check(ok, "6: bursts around thread retirement did not finish (lost wakeup?)")
    check(wrongCount.count == 0, "6: \(wrongCount.count) wrong results")
}

let after = step("7 threads return to baseline (wait up to 8 s)") {
    waitForThreads(atMost: baseline + 2, upTo: 8, onMain: true)
}
say("threads: baseline=\(baseline) after=\(after)")
say("   threads by name after the wait: " + threadNames())
// The system's own queue threads ("unnamed") come and go by two or three at any time, so the count
// alone is no test; what must be gone are the pool's working threads (its one watcher may stay).
let poolThreads = threadCount(named: "AFM.Parallel", except: ".watch")
check(poolThreads == 0, "7: \(poolThreads) threads of the pool are still there 8 s after the last map")
check(after <= baseline + 6, "7: thread count did not return to baseline: \(baseline) -> \(after)")

// The rule itself (K044): work inside a map that the main thread waits for must not wait for the
// main thread, and can find out that it is in that position before it tries.
step("7b the main-thread rule can be asked") {
    let outside = Parallel.isHoldingUpMainThread
    // Bodies that take a while, so that helper threads take pieces too.
    let inside = Parallel.map(Array(0..<256)) { (_: Int) -> (flag: Bool, onMain: Bool) in
        usleep(2_000)
        return (Parallel.isHoldingUpMainThread, Thread.isMainThread)
    }
    let helpers = inside.filter { !$0.onMain }
    var fromBackground: [Bool] = []
    let done = DispatchSemaphore(value: 0)
    Thread {
        fromBackground = Parallel.map(Array(0..<256)) { (_: Int) -> Bool in
            usleep(500)
            return Parallel.isHoldingUpMainThread
        }
        done.signal()
    }.start()
    done.wait()
    let after = Parallel.isHoldingUpMainThread
    say(
        "   flag outside any map on main: \(outside); inside a map called on main: true in \(inside.filter(\.flag).count) of \(inside.count) bodies "
            + "(\(helpers.count) ran on helper threads, true in \(helpers.filter(\.flag).count)); in a map called on a background thread: true in \(fromBackground.filter { $0 }.count) of \(fromBackground.count); after: \(after)"
    )
    check(!outside && !after, "7b: isHoldingUpMainThread is true on the main thread outside a map")
    check(
        inside.allSatisfy(\.flag),
        "7b: a body of a map called on the main thread was not told that it holds up the main thread")
    check(!helpers.isEmpty, "7b: no body ran on a helper thread, so the rule was not tried there")
    check(!fromBackground.contains(true), "7b: a map called on a background thread says it holds up the main thread")
}

// What happens when the rule is broken, in child processes: these two are expected to hang and to
// stop with a trap (release builds have no assertion); they are reported, not counted as failures.
MainWatchdog.shared.setPhase("8 child cases")
runChild("main-in-map-bodies-sync-to-main", patience: 8)
runChild("main-in-map-all-bodies-sync-to-main", patience: 8)

say("threads at the end (about 10 s later): \(threadCount()): " + threadNames())
MainWatchdog.shared.report(title: "Parallel.map torture")
say("\nFAILURES: \(failures.count)")
failures.forEach { say("  - " + $0) }
say(String(format: "peakRSS=%.0fMB", peakRSSMB()))
exit(failures.isEmpty ? 0 : 1)
