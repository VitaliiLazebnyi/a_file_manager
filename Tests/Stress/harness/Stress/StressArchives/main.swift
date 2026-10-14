import AFMKernel
@testable import AFMShell
import AppKit
@testable import ArchivesPlugin
import Foundation
import LocalFileSystemPlugin
import StressKit
import zlib

// Scenario 5: archives. `--mode big` opens and lists the 200,000-member ZIP and then lets 16
// threads read 64 members (with random cancels) while one thread adds members and commits and
// another lists; after every commit the archive is checked with unzip, zipinfo and a fresh
// reader of the program's own. `--mode deep` walks the deeply nested ZIP.

var arguments: [String: String] = [:]
do {
    var rest = Array(CommandLine.arguments.dropFirst())
    while !rest.isEmpty {
        let key = rest.removeFirst()
        arguments[key] = rest.isEmpty || rest[0].hasPrefix("--") ? "1" : rest.removeFirst()
    }
}
func argument(_ name: String, _ fallback: Int) -> Int { arguments[name].flatMap(Int.init) ?? fallback }
let directory = URL(fileURLWithPath: arguments["--dir"] ?? FileManager.default.currentDirectoryPath)
let mode = arguments["--mode"] ?? "big"
let duration = Double(argument("--seconds", 60))
let readerCount = argument("--readers", 16)
let expectedEntries = argument("--entries", 200_000)
let chainDepth = argument("--chain", 2000)
let results = arguments["--results"] ?? FileManager.default.currentDirectoryPath
let seed = UInt64(argument("--seed", 1))

final class Findings {
    private let lock = NSLock()
    private(set) var violations: [String: Int] = [:]
    private var examples: [String: [String]] = [:]

    func violation(_ kind: String, _ detail: String) {
        lock.lock()
        violations[kind, default: 0] += 1
        let shows = examples[kind, default: []].count < 6
        if shows { examples[kind, default: []].append(detail) }
        lock.unlock()
        if shows { say("!! VIOLATION [\(kind)] \(detail)") }
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

final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

final class Counter {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var times: [String: [Double]] = [:]
    func add(_ name: String, _ amount: Int = 1) { lock.lock(); counts[name, default: 0] += amount; lock.unlock() }
    func time(_ name: String, _ seconds: Double) { lock.lock(); times[name, default: []].append(seconds); lock.unlock() }
    func get(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[name] ?? 0 }
    func report() {
        lock.lock(); defer { lock.unlock() }
        for (name, count) in counts.sorted(by: { $0.key < $1.key }) { say("COUNT \(name) = \(count)") }
        for (name, values) in times.sorted(by: { $0.key < $1.key }) {
            let sorted = values.sorted()
            say(String(format: "TIME %@: n=%d min=%.1fms median=%.1fms p95=%.1fms max=%.1fms", name, sorted.count, sorted[0] * 1000,
                       sorted[sorted.count / 2] * 1000, sorted[min(sorted.count - 1, sorted.count * 95 / 100)] * 1000, sorted.last! * 1000))
        }
    }
}

let counter = Counter()

func offMain<T>(_ body: @escaping () -> T) -> T {
    let done = Box<T?>(nil)
    let thread = Thread { let value = body(); DispatchQueue.main.async { done.value = value } }
    thread.stackSize = 64 << 20
    thread.start()
    pump(upTo: 7200) { done.value != nil }
    return done.value!
}

func checksum(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { UInt32(truncatingIfNeeded: crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count))) }
}

func tool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The program's archive file systems, set up as the plugin sets them up.
final class Bench {
    let environment = ArchiveEnvironment()
    let store: ArchiveStore
    let fileSystems = FileSystemRegistry()
    let zip: ArchiveFileSystem
    let readOnly: ArchiveFileSystem

    init(flushDelay: TimeInterval? = 1) {
        environment.flushDelay = flushDelay
        store = ArchiveStore(environment: environment)
        zip = ArchiveFileSystem(scheme: ArchiveURL.writableScheme, store: store)
        readOnly = ArchiveFileSystem(scheme: ArchiveURL.readOnlyScheme, store: store)
        fileSystems.register(LocalFileSystem())
        fileSystems.register(zip)
        fileSystems.register(readOnly)
        environment.fileSystems = { [weak fileSystems] in fileSystems }
        environment.reportFailure = { error, name in findings.violation("archive reported a failed write", "\(name): \(error.localizedDescription)") }
        environment.contentsChanged = { _ in
            counter.add("contentsChanged callbacks")
            DispatchQueue.main.async { counter.add("contentsChanged on main") }
        }
    }

    func inside(_ archive: URL, _ path: String = "") -> URL { ArchiveURL.make(scheme: ArchiveURL.writableScheme, archive: archive, innerPath: path) }

    /// Reads a member to its end; nil with the error when it failed.
    func readAll(_ url: URL) -> (data: Data?, error: Error?) {
        do {
            let reader = try zip.read(url)
            defer { reader.close() }
            var all = Data()
            while let block = try reader.read(upToCount: 1 << 20) { all.append(block) }
            return (all, nil)
        } catch {
            return (nil, error)
        }
    }
}

/// Loads a location the way a panel does (PanelLoading: background read, pieces on the main
/// thread) and returns the time to the first piece and to the end, and the item count.
func panelLoad(_ bench: Bench, _ location: URL) -> (first: Double, total: Double, count: Int, error: Error?) {
    let started = now()
    var first = 0.0, count = 0
    var ended = false
    var failure: Error?
    let loading = PanelLoading(location: location, showHidden: true, order: ListOrder(), fileSystems: bench.fileSystems, cache: ListingCache(),
                               cancellation: CancellationFlag())
    loading.start(onPiece: { piece in
        if first == 0 { first = now() - started }
        count = piece.listing.items.count
    }, onEnd: { error in
        failure = error
        ended = true
    })
    pump(upTo: 600) { ended }
    return (first, now() - started, count, failure)
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
HangGuard.shared.sampleDirectory = results
MainWatchdog.shared.start()
say("StressArchives mode=\(mode) dir=\(directory.path) cores=\(ProcessInfo.processInfo.activeProcessorCount) load=\(loadAverage())")
step("idle baseline") { pump(for: 1.5) }
let baselineThreads = threadCount()

// MARK: The big archive

struct Probe {
    let path: String
    let data: Data
    let crc: UInt32
}

func runBig() {
    let archive = directory.appendingPathComponent("big.zip")
    let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
    say("big.zip: \(size >> 20) MB")
    var probes: [Probe] = []
    for line in (try! String(contentsOf: directory.appendingPathComponent("probe.tsv"), encoding: .utf8)).split(separator: "\n") {
        let parts = line.split(separator: "\t")
        let data = try! Data(contentsOf: directory.appendingPathComponent("probe-ref").appendingPathComponent(String(parts[0].split(separator: "/")[1])))
        precondition(data.count == Int(parts[1])! && checksum(data) == UInt32(parts[2])!, "reference of \(parts[0]) is wrong")
        probes.append(Probe(path: String(parts[0]), data: data, crc: UInt32(parts[2])!))
    }
    say("probes: \(probes.count) members, \(probes.reduce(0) { $0 + $1.data.count } >> 20) MB")
    let bench = Bench()
    let root = bench.inside(archive)
    let folders = expectedEntries / 500

    let before = footprintMB()
    step("open + list root (panel path)", limit: 300) {
        let loaded = panelLoad(bench, root)
        say(String(format: "LOAD root: first piece %.3fs, complete %.3fs, %d items, error=%@", loaded.first, loaded.total, loaded.count, "\(String(describing: loaded.error))"))
        if loaded.count != folders + 1 { findings.violation("root listing has the wrong number of items", "\(loaded.count) instead of \(folders + 1)") }
    }
    say(String(format: "MEMORY open archive with %d members: footprint %.0f MB -> %.0f MB (%.0f bytes per member)", expectedEntries + 64, before, footprintMB(),
               (footprintMB() - before) * 1_048_576 / Double(expectedEntries + 64)))
    step("list root again (archive open)") {
        let loaded = panelLoad(bench, root)
        say(String(format: "LOAD root again: first %.3fs complete %.3fs", loaded.first, loaded.total))
    }
    step("list one folder of 500 (panel path)") {
        let loaded = panelLoad(bench, bench.inside(archive, "dir0001"))
        say(String(format: "LOAD dir0001: first %.4fs complete %.4fs, %d items", loaded.first, loaded.total, loaded.count))
        if loaded.count != 500 { findings.violation("folder listing has the wrong number of items", "dir0001: \(loaded.count)") }
    }
    step("list every folder (\(folders) listings, 1 thread)", limit: 600) {
        let total: Int = offMain {
            var total = 0
            for folder in 0..<folders { total += (try? bench.zip.list(bench.inside(archive, String(format: "dir%04d", folder)), showHidden: true).count) ?? 0 }
            return total
        }
        if total != expectedEntries { findings.violation("listings of all folders do not add up", "\(total) instead of \(expectedEntries)") }
    }
    step("list every folder (16 threads at once)", limit: 600) {
        let total: Int = offMain {
            let sum = Box(0)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: folders) { folder in
                let count = (try? bench.zip.list(bench.inside(archive, String(format: "dir%04d", folder)), showHidden: true).count) ?? 0
                lock.lock(); sum.value += count; lock.unlock()
            }
            return sum.value
        }
        if total != expectedEntries { findings.violation("parallel listings of all folders do not add up", "\(total) instead of \(expectedEntries)") }
    }
    step("harness loop on main: item(at:)+capabilities x20k") {
        // What the shell asks on the main thread for an open archive.
        var random = Random(seed: seed)
        var missing = 0
        for _ in 0..<20_000 {
            let index = Int.random(in: 0..<expectedEntries, using: &random)
            if bench.zip.item(at: bench.inside(archive, String(format: "dir%04d/f%06d.txt", index / 500, index))) == nil { missing += 1 }
            _ = bench.zip.capabilities(for: root)
        }
        if missing > 0 { findings.violation("item(at:) did not find a member", "\(missing) of 20000") }
    }
    step("read all 64 probes once, verify") {
        offMain {
            for probe in probes {
                let got = bench.readAll(bench.inside(archive, probe.path))
                if got.data != probe.data { findings.violation("probe read wrong before any change", "\(probe.path): \(String(describing: got.error))") }
            }
        }
    }

    // The concurrent part.
    let stop = CancellationFlag()
    let lock = NSLock()
    /// Members that are in the archive for good: the probes, and what was added and committed.
    var readable = probes
    var committedFiles = expectedEntries + probes.count
    var threads: [Thread] = []
    let alive = Box(0)
    let aliveLock = NSLock()
    func launch(_ name: String, _ body: @escaping () -> Void) {
        aliveLock.lock(); alive.value += 1; aliveLock.unlock()
        let thread = Thread {
            body()
            aliveLock.lock(); alive.value -= 1; aliveLock.unlock()
        }
        thread.name = name
        thread.stackSize = 8 << 20
        threads.append(thread)
        thread.start()
    }
    let cancelQueue = DispatchQueue(label: "stress.cancel", attributes: .concurrent)

    MainWatchdog.shared.setPhase("concurrent: 16 readers + adder/commit + lister")
    HangGuard.shared.arm("concurrent archive stage", seconds: duration + 240)
    let stageStart = now()
    let (cpu0, footprint0) = (cpuSeconds(), footprintMB())

    for reader in 0..<readerCount {
        launch("Stress.Reader\(reader)") {
            var random = Random(seed: seed &* 1000 &+ UInt64(reader))
            while !stop.isCancelled {
                lock.lock()
                // Mostly the 64 probes; sometimes a member that was added meanwhile.
                let probe = Int.random(in: 0..<10, using: &random) < 8 ? readable[Int.random(in: 0..<probes.count, using: &random)] : readable[Int.random(in: 0..<readable.count, using: &random)]
                lock.unlock()
                let url = bench.inside(archive, probe.path)
                let flag = CancellationFlag()
                let cancels = Int.random(in: 0..<10, using: &random) < 3
                let seeks = Int.random(in: 0..<10, using: &random) < 2 && probe.data.count > 2
                let blockSize = [4 << 10, 64 << 10, 1 << 20][Int.random(in: 0..<3, using: &random)]
                let started = now()
                var got = 0
                var crc: uLong = 0
                var matches = true
                var offset = 0
                let cancelledAt = Box(0.0)
                do {
                    let reader = try bench.zip.read(url, cancellation: flag)
                    defer { reader.close() }
                    let tie = flag.interrupting(reader)
                    defer { withExtendedLifetime(tie) {} }
                    if cancels {
                        let delay = Int.random(in: 0...(probe.data.count > (1 << 20) ? 30_000 : 1_500), using: &random)
                        cancelQueue.asyncAfter(deadline: .now() + .microseconds(delay)) { cancelledAt.value = now(); flag.cancel() }
                    }
                    if seeks {
                        offset = Int.random(in: 0..<probe.data.count, using: &random)
                        try reader.seek(to: UInt64(offset))
                    }
                    while let block = try reader.read(upToCount: blockSize) {
                        if block.isEmpty { findings.violation("reader returned an empty block instead of nil", probe.path); break }
                        // Compared piece by piece with the reference, so the harness keeps no copy.
                        let at = offset + got
                        if at + block.count > probe.data.count { matches = false; got += block.count; break }
                        block.withUnsafeBytes { piece in
                            probe.data.withUnsafeBytes { whole in
                                if memcmp(piece.baseAddress, whole.baseAddress! + at, block.count) != 0 { matches = false }
                            }
                            crc = crc32(crc, piece.bindMemory(to: UInt8.self).baseAddress, uInt(block.count))
                        }
                        got += block.count
                    }
                    // Read to the end without an error: the bytes must be right, cancelled or not.
                    if !matches || offset + got != probe.data.count {
                        findings.violation("WRONG BYTES read from a member", "\(probe.path) offset \(offset): got \(got) bytes, expected \(probe.data.count - offset), content matches=\(matches); cancelled=\(flag.isCancelled)")
                    } else if offset == 0, UInt32(truncatingIfNeeded: crc) != probe.crc {
                        findings.violation("CRC mismatch", probe.path)
                    }
                    counter.add(flag.isCancelled ? "reads completed although cancelled" : "reads completed and verified")
                    counter.add("bytes read and verified", got)
                } catch {
                    if flag.isCancelled {
                        counter.add("reads ended by cancel")
                        if cancelledAt.value > 0 { counter.time("cancel -> read ended", now() - cancelledAt.value) }
                    } else {
                        findings.violation("read failed without a cancel", "\(probe.path) offset \(offset): \(error.localizedDescription)")
                    }
                }
                counter.time(probe.data.count > (8 << 20) ? "read of a 24 MB member (incl. cancelled)" : "read of a small/medium member (incl. cancelled)", now() - started)
            }
        }
    }

    launch("Stress.Lister") {
        var random = Random(seed: seed &* 77)
        var lastAdded = 0
        while !stop.isCancelled {
            let started = now()
            do {
                let top = try bench.zip.list(root, showHidden: true, cancellation: CancellationFlag())
                if top.count < folders + 1 || top.count > folders + 2 { findings.violation("root listing wrong during the changes", "\(top.count) items") }
                counter.time("list root", now() - started)
                let folder = Int.random(in: 0..<folders, using: &random)
                let t1 = now()
                let items = try bench.zip.list(bench.inside(archive, String(format: "dir%04d", folder)), showHidden: true, cancellation: CancellationFlag())
                counter.time("list folder of 500", now() - t1)
                if items.count != 500 { findings.violation("folder listing wrong during the changes", "dir\(folder): \(items.count)") }
                if top.contains(where: { $0.name == "added" }) {
                    let batches = try bench.zip.list(bench.inside(archive, "added"), showHidden: true)
                    if batches.count < lastAdded { findings.violation("the added folder shrank", "\(lastAdded) -> \(batches.count)") }
                    lastAdded = batches.count
                }
                let index = Int.random(in: 0..<expectedEntries, using: &random)
                if bench.zip.item(at: bench.inside(archive, String(format: "dir%04d/f%06d.txt", index / 500, index))) == nil {
                    findings.violation("item(at:) lost a member during the changes", "f\(index)")
                }
                counter.add("listing rounds")
            } catch {
                findings.violation("listing failed", "\(error.localizedDescription)")
            }
        }
    }

    launch("Stress.Adder") {
        var random = Random(seed: seed &* 4242)
        var batch = 0
        while !stop.isCancelled {
            batch += 1
            var added: [Probe] = []
            let count = Int.random(in: 1...20, using: &random)
            for file in 0..<count {
                let size = Int.random(in: 0..<20, using: &random) == 0 ? Int.random(in: (2 << 20)...(6 << 20), using: &random) : Int.random(in: 0...(200 << 10), using: &random)
                var data = Data(count: size)
                // Half compressible.
                data.withUnsafeMutableBytes { raw in
                    let buffer = raw.bindMemory(to: UInt8.self)
                    var state = UInt64(batch) &* 1_000_003 &+ UInt64(file)
                    for position in 0..<size {
                        if position % 2 == 0 { state = state &* 6364136223846793005 &+ 1442695040888963407 }
                        buffer[position] = position % 2 == 0 ? UInt8(truncatingIfNeeded: state >> 33) : UInt8(65 + position % 7)
                    }
                }
                let path = String(format: "added/batch%04d/new%03d.bin", batch, file)
                do {
                    let writer = try bench.zip.write(bench.inside(archive, path), cancellation: CancellationFlag())
                    var position = 0
                    while position < size {
                        let end = min(size, position + (256 << 10))
                        try writer.write(data.subdata(in: position..<end))
                        position = end
                    }
                    try writer.close(attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_700_000_000), permissions: 0o644))
                    added.append(Probe(path: path, data: data, crc: checksum(data)))
                } catch {
                    findings.violation("adding a member failed", "\(path): \(error.localizedDescription)")
                }
            }
            let t0 = now()
            do {
                try bench.zip.commit(root, cancellation: CancellationFlag())
            } catch {
                findings.violation("commit failed", "batch \(batch): \(error.localizedDescription)")
                continue
            }
            counter.time("commit (\(expectedEntries / 1000)k-member archive)", now() - t0)
            counter.add("commits")
            if counter.get("commits") % 5 == 0 {
                say(String(format: "MEM after commit %d: footprint=%.0f MB (harness holds %.0f MB of added reference data) t=%.1fs", counter.get("commits"), footprintMB(), Double(counter.get("reference bytes held")) / 1_048_576, now() - stageStart))
            }
            counter.add("reference bytes held", added.reduce(0) { $0 + $1.data.count })
            counter.add("members added", added.count)
            lock.lock()
            committedFiles += added.count
            let expectedFiles = committedFiles
            lock.unlock()

            // 1. unzip -tq: every member's CRC, by another program.
            let t1 = now()
            let test = tool("/usr/bin/unzip", ["-tq", archive.path])
            counter.time("unzip -tq", now() - t1)
            if test.status != 0 || !test.output.contains("No errors detected") {
                findings.violation("ARCHIVE INVALID after a commit (unzip -tq)", "batch \(batch): status \(test.status): \(test.output.suffix(300))")
            }
            // 2. zipinfo: the directory lists what was added.
            let info = tool("/usr/bin/zipinfo", ["-1", archive.path, "added/batch\(String(format: "%04d", batch))/*"])
            let listed = Set(info.output.split(separator: "\n").map(String.init))
            for probe in added where !listed.contains(probe.path) {
                findings.violation("zipinfo does not list a committed member", "\(probe.path) (status \(info.status))")
            }
            let totals = tool("/usr/bin/zipinfo", ["-t", archive.path])
            if totals.status != 0 { findings.violation("zipinfo -t failed after a commit", "batch \(batch): \(totals.output.suffix(200))") }
            // 3. The program's own reader, from scratch: counts, and the bytes of what was just added.
            let t2 = now()
            let fresh = Bench(flushDelay: nil)
            do {
                let opened = try fresh.store.archive(at: archive)
                let files = opened.entries.filter { !$0.isDirectory }.count
                if files != expectedFiles { findings.violation("fresh reader counts other members than were committed", "batch \(batch): \(files) instead of \(expectedFiles)") }
                for probe in added {
                    let got = fresh.readAll(fresh.inside(archive, probe.path))
                    if got.data != probe.data { findings.violation("COMMITTED MEMBER READS BACK WRONG (fresh reader)", "\(probe.path): \(String(describing: got.error))") }
                }
                let old = probes[Int.random(in: 0..<probes.count, using: &random)]
                if fresh.readAll(fresh.inside(archive, old.path)).data != old.data { findings.violation("old member damaged after a commit (fresh reader)", old.path) }
            } catch {
                findings.violation("ARCHIVE UNREADABLE by a fresh reader after a commit", "batch \(batch): \(error.localizedDescription)")
            }
            fresh.store.close()
            counter.time("fresh reader open + verify", now() - t2)
            lock.lock()
            readable += added
            lock.unlock()
        }
    }

    pump(for: duration)
    stop.cancel()
    MainWatchdog.shared.setPhase("concurrent: waiting for the threads to end")
    let ended = pump(upTo: 180) { aliveLock.lock(); defer { aliveLock.unlock() }; return alive.value == 0 }
    if !ended {
        findings.violation("THREADS DID NOT END (deadlock?)", "\(alive.value) of \(threads.count) still running 180 s after stop; see the hang sample")
        HangGuard.shared.arm("archive threads did not end", seconds: 0.1)
        pump(for: 30)
    }
    HangGuard.shared.disarm()
    let wall = now() - stageStart
    say(String(format: "STAGE concurrent: wall=%.1fs cpu=%.1fs (%.1f cores) footprint %.0f->%.0f MB peakRSS=%.0f MB threads=%d load=%.1f", wall, cpuSeconds() - cpu0,
               (cpuSeconds() - cpu0) / wall, footprint0, footprintMB(), peakRSSMB(), threadCount(), loadAverage()))

    step("after: wait for delayed writes, final checks", limit: 300) {
        pump(for: 2.5)
        offMain {
            if let open = bench.store.openArchive(at: archive), open.hasPendingChanges { findings.violation("changes still pending after the last commit", "") }
            let test = tool("/usr/bin/unzip", ["-tq", archive.path])
            if test.status != 0 { findings.violation("ARCHIVE INVALID at the end (unzip -tq)", String(test.output.suffix(300))) }
            say("final unzip -tq: \(test.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))")
            say("final zipinfo -t: \(tool("/usr/bin/zipinfo", ["-t", archive.path]).output.trimmingCharacters(in: .whitespacesAndNewlines))")
            // Every member that was ever committed, through the long-lived store.
            lock.lock(); let all = readable; lock.unlock()
            var wrong = 0
            for probe in all where bench.readAll(bench.inside(archive, probe.path)).data != probe.data { wrong += 1 }
            if wrong > 0 { findings.violation("members read back wrong at the end (long-lived store)", "\(wrong) of \(all.count)") }
            say("final: \(all.count) probe/added members verified through the long-lived store, wrong=\(wrong)")
        }
    }
    step("close the store") { bench.store.close() }
    say(String(format: "MEM after closing the store: footprint=%.0f MB", footprintMB()))
    step("hazard: item(at:) on main while another thread opens the same archive", limit: 300) {
        // Not something the harness saw the shell do; it measures what a main-thread caller would wait.
        let fresh = Bench(flushDelay: nil)
        let opened = Box(false)
        let thread = Thread { _ = try? fresh.store.archive(at: archive); opened.value = true }
        thread.start()
        usleep(20_000)
        let t0 = now()
        let found = fresh.zip.item(at: fresh.inside(archive, "dir0001/f000500.txt"))
        say(String(format: "HAZARD item(at:) without a flag, called on main 20 ms after another thread began opening the archive: returned after %.0f ms (found=%@, opener done=%@)", (now() - t0) * 1000, found == nil ? "no" : "yes", opened.value ? "yes" : "no"))
        pump(upTo: 60) { opened.value }
        fresh.store.close()
    }
    if arguments["--leaks"] != nil {
        step("leaks(1) on this process", limit: 900) {
            let report: String = offMain { tool("/usr/bin/leaks", ["\(getpid())"]).output }
            let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines where line.contains("total leaked bytes") || line.contains("Physical footprint") || line.contains("nodes malloced") { say("LEAKS " + line) }
            try? report.write(toFile: results + "/archives-leaks.txt", atomically: true, encoding: .utf8)
        }
    }
    MainWatchdog.shared.setPhase("settle (idle)")
    let settled = waitForThreads(atMost: baselineThreads, upTo: 8, onMain: true)
    say("THREADS baseline=\(baselineThreads) settled(<=8s)=\(settled)")
    // The system's queue threads come and go by a few; what must be gone are the program's own named threads.
    let own = threadCount(named: "AFM.", except: ".watch")
    say("THREADS by name: " + threadNames())
    if settled > baselineThreads + 2, own > 0 { findings.violation("threads did not return to baseline", "\(settled) vs \(baselineThreads), \(own) of the program's own: " + threadNames()) }
    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0 != "big.zip" && $0 != "deep.zip" && $0 != "probe.tsv" && $0 != "probe-ref" && !$0.hasSuffix(".pristine.zip") }
    if !leftovers.isEmpty { findings.violation("files left next to the archive", leftovers.prefix(5).joined(separator: ", ")) }
}

// MARK: The deep archive

func runDeep() {
    let archive = directory.appendingPathComponent("deep.zip")
    let bench = Bench()
    let root = bench.inside(archive)
    step("deep: open + list root (panel path)", limit: 300) {
        let loaded = panelLoad(bench, root)
        say(String(format: "LOAD deep root: first %.3fs complete %.3fs, %d items error=%@", loaded.first, loaded.total, loaded.count, "\(String(describing: loaded.error))"))
        if loaded.count != 3 { findings.violation("deep root listing wrong", "\(loaded.count) items") }
    }
    step("deep: walk down the chain of \(chainDepth) folders (list each level)", limit: 600) {
        let reached: Int = offMain {
            var url = root
            var level = 0
            var slowest = 0.0
            while true {
                let t0 = now()
                guard let items = try? bench.zip.list(url, showHidden: true), let next = items.first(where: { $0.isDirectory && $0.name == "c" }) else { break }
                slowest = max(slowest, now() - t0)
                url = next.url
                level += 1
            }
            say(String(format: "deep chain: reached level %d, slowest listing %.2f ms", level, slowest * 1000))
            let leaf = bench.readAll(url.appending(name: "leaf.txt"))
            if leaf.data != Data("bottom of the chain\n".utf8) { findings.violation("deep leaf read wrong", "\(String(describing: leaf.error))") }
            return level
        }
        if reached != chainDepth { findings.violation("deep chain not walked to the bottom", "level \(reached) of \(chainDepth)") }
    }
    step("deep: panel load at the bottom of the chain", limit: 300) {
        let bottom = bench.inside(archive, Array(repeating: "c", count: chainDepth).joined(separator: "/"))
        let loaded = panelLoad(bench, bottom)
        say(String(format: "LOAD deep bottom: first %.3fs complete %.3fs, %d items error=%@", loaded.first, loaded.total, loaded.count, "\(String(describing: loaded.error))"))
        if loaded.count != 1 { findings.violation("deep bottom listing wrong", "\(loaded.count) items, error \(String(describing: loaded.error))") }
        // What the path bar and the title show, on the main thread.
        _ = bench.fileSystems.displayPath(bottom)
        _ = bench.zip.parent(of: bottom)
        _ = bench.zip.item(at: bottom)
    }
    step("deep: walk the binary tree (8191 folders) and read every node", limit: 600) {
        let nodes: Int = offMain {
            var count = 0
            func visit(_ url: URL) {
                guard let items = try? bench.zip.list(url, showHidden: true) else { return }
                for item in items {
                    if item.isDirectory { visit(item.url) } else {
                        if bench.readAll(item.url).data == nil { findings.violation("deep tree member unreadable", item.url.path) }
                        count += 1
                    }
                }
            }
            visit(bench.inside(archive, "t"))
            return count
        }
        if nodes != 8191 { findings.violation("deep tree has the wrong number of members", "\(nodes)") }
    }
    step("deep: the member with a 60,000-byte path", limit: 300) {
        offMain {
            var url = bench.inside(archive, "long")
            var levels = 0
            while let items = try? bench.zip.list(url, showHidden: true), let next = items.first {
                if !next.isDirectory {
                    if bench.readAll(next.url).data != Data("long path\n".utf8) { findings.violation("long-path member read wrong", "") }
                    break
                }
                url = next.url
                levels += 1
            }
            say("long path: \(levels) levels walked")
            if levels != 238 { findings.violation("long path not walked to its end", "\(levels) of 238") }
        }
    }
    step("deep: add at the bottom + commit + unzip -tq + fresh reader", limit: 600) {
        offMain {
            let bottom = bench.inside(archive, Array(repeating: "c", count: chainDepth).joined(separator: "/") + "/added.txt")
            do {
                let writer = try bench.zip.write(bottom)
                try writer.write(Data("added at the bottom\n".utf8))
                try writer.close(attributes: FileAttributes())
                let t0 = now()
                try bench.zip.commit(root, cancellation: CancellationFlag())
                say(String(format: "deep commit: %.3fs", now() - t0))
            } catch {
                findings.violation("deep: adding at the bottom failed", error.localizedDescription)
            }
            let test = tool("/usr/bin/unzip", ["-tq", archive.path])
            say("deep unzip -tq: status \(test.status) \(test.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(160))")
            // unzip warns "filename too long" for the pristine archive already (status 1): only a real error counts,
            // and Python's zipfile checks every CRC without that limit.
            if test.status > 1 { findings.violation("deep archive invalid after the commit (unzip -tq)", String(test.output.suffix(300))) }
            let python = tool("/usr/bin/env", ["python3", "-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); print('testzip', z.testzip(), 'members', len(z.namelist()))", archive.path])
            say("deep python zipfile: \(python.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))")
            if !python.output.contains("testzip None") { findings.violation("deep archive invalid after the commit (python zipfile)", String(python.output.suffix(300))) }
            let fresh = Bench(flushDelay: nil)
            if fresh.readAll(fresh.inside(archive, Array(repeating: "c", count: chainDepth).joined(separator: "/") + "/added.txt")).data != Data("added at the bottom\n".utf8) {
                findings.violation("deep: committed member reads back wrong (fresh reader)", "")
            }
            let count = (try? fresh.store.archive(at: archive).entries.filter { !$0.isDirectory }.count) ?? -1
            if count != 8194 { findings.violation("deep: fresh reader counts wrong", "\(count) instead of 8194") }
            fresh.store.close()
        }
    }
    step("deep: close the store") { bench.store.close() }
}

if mode == "big" { runBig() } else { runDeep() }
MainWatchdog.shared.setPhase("end")
counter.report()
findings.summary()
MainWatchdog.shared.report(title: "StressArchives \(mode)")
say(String(format: "FINAL threads=%d (baseline %d) peakRSS=%.0fMB footprint=%.0fMB load=%.1f", threadCount(), baselineThreads, peakRSSMB(), footprintMB(), loadAverage()))
exit(findings.violations.isEmpty ? 0 : 3)
