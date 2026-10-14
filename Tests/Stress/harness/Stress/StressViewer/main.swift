import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import StressKit
import TestSupport

@testable import ViewerPlugin

// Scenario 7: the viewer's text model (TextDocument / TextRowIndex / ViewerSearch) and the real
// TextPagerView on top of it, without a window.
//
//   StressViewer gen <dir>                      dense4g.txt, sparse4g.txt, line2g.txt, newlines1g.txt (11 GiB)
//   StressViewer dense <file> <megabytes>       one dense text file of that size
//   StressViewer leak <file> <resultsDir>       memory per call of the model's entry points (search above all)
//   StressViewer run <file> <resultsDir> [seed] one file through every step
//   StressViewer truncate <dir> <resultsDir> [rounds]   a file cut short (and removed) while it is indexed

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    say("usage")
    exit(2)
}
let marker = "ENDMARKER_QZX"

// MARK: Files

func denseBlock(_ size: Int, seed: UInt64) -> (data: Data, lines: Int) {
    var random = Random(seed: seed)
    let words = [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do", "eiusmod", "tempor"
    ]
    var bytes: [UInt8] = []
    bytes.reserveCapacity(size)
    var lines = 0
    while bytes.count < size {
        let left = size - bytes.count
        var length = 60 + Int(random.next() % 40)
        if left < 200 { length = left - 1 }
        var line: [UInt8] = []
        while line.count < length {
            line.append(contentsOf: Array(words[Int(random.next() % UInt64(words.count))].utf8))
            line.append(0x20)
        }
        bytes.append(contentsOf: line.prefix(length))
        bytes.append(0x0A)
        lines += 1
    }
    return (Data(bytes), lines)
}

func writeDense(_ url: URL, megabytes: Int) -> Int {
    let (block, lines) = denseBlock(1 << 20, seed: 11)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try! FileHandle(forWritingTo: url)
    for _ in 0..<megabytes - 1 { handle.write(block) }
    // The last block ends with a line that exists nowhere else.
    var last = block
    let tail = Array((marker + "\n").utf8)
    last.replaceSubrange(last.count - tail.count..<last.count, with: tail)
    // The byte before the marker was part of the last line: still one line, a little shorter.
    handle.write(last)
    try! handle.close()
    return lines * megabytes
}

func generate(_ directory: URL) {
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var t = now()
    let lines = writeDense(directory.appendingPathComponent("dense4g.txt"), megabytes: 4096)
    say(
        String(
            format: "dense4g.txt: 4 GiB, %d lines (the marker line is cut out of the last one), %.1fs", lines,
            now() - t))

    // 4 GiB, of which every 8 MiB begin with 2 MiB of text; the rest was never written (holes of NUL).
    t = now()
    let sparse = directory.appendingPathComponent("sparse4g.txt")
    FileManager.default.createFile(atPath: sparse.path, contents: nil)
    let descriptor = open(sparse.path, O_RDWR)
    ftruncate(descriptor, 4 << 30)
    let (two, twoLines) = denseBlock(2 << 20, seed: 12)
    for stretch in 0..<512 {
        two.withUnsafeBytes { _ = pwrite(descriptor, $0.baseAddress, $0.count, off_t(stretch) * (8 << 20)) }
    }
    close(descriptor)
    say(
        String(
            format: "sparse4g.txt: 4 GiB apparent, 512 x 2 MiB of text (%d lines each) with 6 MiB holes, %.1fs",
            twoLines, now() - t))

    t = now()
    let single = directory.appendingPathComponent("line2g.txt")
    FileManager.default.createFile(atPath: single.path, contents: nil)
    var handle = try! FileHandle(forWritingTo: single)
    let phrase = Array("lorem ipsum dolor sit amet ".utf8)
    var block: [UInt8] = []
    while block.count < 1 << 20 { block.append(contentsOf: phrase) }
    block.removeLast(block.count - (1 << 20))
    let data = Data(block)
    for _ in 0..<2047 { handle.write(data) }
    var last = data
    last.replaceSubrange(last.count - marker.utf8.count..<last.count, with: Array(marker.utf8))
    handle.write(last)
    try! handle.close()
    say(String(format: "line2g.txt: one line of 2 GiB, %.1fs", now() - t))

    t = now()
    let newlines = directory.appendingPathComponent("newlines1g.txt")
    FileManager.default.createFile(atPath: newlines.path, contents: nil)
    handle = try! FileHandle(forWritingTo: newlines)
    let feed = Data(repeating: 0x0A, count: 1 << 20)
    for _ in 0..<1024 { handle.write(feed) }
    try! handle.close()
    say(String(format: "newlines1g.txt: 1 GiB of line feeds, %.1fs", now() - t))
}

if arguments[1] == "gen" {
    generate(URL(fileURLWithPath: arguments[2]))
    exit(0)
}
// One dense text file of a chosen size: `StressViewer dense <file> <megabytes>`.
if arguments[1] == "dense", arguments.count >= 4, let megabytes = Int(arguments[3]), megabytes >= 1 {
    let lines = writeDense(URL(fileURLWithPath: arguments[2]), megabytes: megabytes)
    say("\(arguments[2]): \(megabytes) MiB, \(lines) lines")
    exit(0)
}

// MARK: Common

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
MainWatchdog.shared.start()
let resultsDirectory = arguments[3]
HangGuard.shared.sampleDirectory = resultsDirectory
let kernel = Kernel(productName: "Stress", settings: MemorySettings(), ui: ScriptedInteraction())
kernel.fileSystems.register(LocalFileSystem())

let failureLock = NSLock()
var failures: [String] = []
var failureCounts: [String: Int] = [:]
/// Recorded once per kind, counted every time. Any thread.
func fail(_ kind: String, _ detail: @autoclosure () -> String) {
    failureLock.lock()
    failureCounts[kind, default: 0] += 1
    let first = failureCounts[kind] == 1
    if first { failures.append(kind + ": " + detail()) }
    failureLock.unlock()
    if first { say("FAIL " + kind + ": " + detail()) }
}

func openSource(_ url: URL) -> ByteSource {
    // As ViewerPane does for a local file: opened in the background, read through a block cache.
    var source: ByteSource?
    DispatchQueue.global(qos: .userInitiated).async {
        let opened = try! ProviderByteSource.open(url, fileSystems: kernel.fileSystems)
        let cached = CachedByteSource(opened)
        DispatchQueue.main.async { source = cached }
    }
    pump(upTo: 60) { source != nil }
    return source!
}

struct OpStats {
    var count = 0
    var total = 0.0
    var maxMs = 0.0
    var cancelled = 0
    var threw = 0
}

/// Threads that call the document as the contract allows ("safe to call from several
/// threads"): rows, the row of an offset, the row of a line, text of a range, searches; many
/// of the calls are cancelled from yet another thread after a random moment.
final class Hammer {
    let document: TextDocument
    let columns: Int
    let label: String
    private let lock = NSLock()
    private var stopped = false
    private var stats: [String: OpStats] = [:]
    private let group = DispatchGroup()

    init(_ document: TextDocument, columns: Int, label: String) {
        self.document = document
        self.columns = columns
        self.label = label
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func note(_ op: String, _ seconds: Double, cancelled: Bool, threw: Bool) {
        lock.lock()
        var entry = stats[op] ?? OpStats()
        entry.count += 1
        entry.total += seconds
        entry.maxMs = max(entry.maxMs, seconds * 1000)
        if cancelled { entry.cancelled += 1 }
        if threw { entry.threw += 1 }
        stats[op] = entry
        lock.unlock()
    }

    func check(_ rows: [DisplayRow], first: Int, flagCancelled: Bool) {
        for (position, row) in rows.enumerated() {
            if row.index != first + position {
                fail("\(label): row number", "asked from \(first), got index \(row.index) at position \(position)")
            }
            if position > 0, row.range.lowerBound != rows[position - 1].range.upperBound {
                fail(
                    "\(label): rows not contiguous",
                    "row \(row.index) begins at \(row.range.lowerBound), the one before ends at \(rows[position - 1].range.upperBound)"
                )
            }
            if row.text.utf16.count > columns * 2 {
                fail(
                    "\(label): row wider than the layout",
                    "row \(row.index) has \(row.text.utf16.count) units, layout \(columns)")
            }
            if row.range.upperBound > document.content.upperBound || row.range.lowerBound < document.content.lowerBound
            {
                fail("\(label): row outside the content", "row \(row.index) \(row.range)")
            }
        }
    }

    func start(threads: Int, searchers: Int, seed: UInt64) {
        let (threads, searchers) = noHammer ? (0, 0) : (threads, noSearchers ? 0 : searchers)
        for index in 0..<threads + searchers {
            group.enter()
            let thread = Thread { [self] in
                var random = Random(seed: seed &* 1000 &+ UInt64(index))
                let isSearcher = index >= threads
                while !isStopped {
                    autoreleasepool {
                        let flag = CancellationFlag()
                        let cancels = random.next() % 10 < 3
                        if cancels {
                            let delay = Int(random.next() % (isSearcher ? 50_000 : 3_000))
                            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                                deadline: .now() + .microseconds(delay)
                            ) { flag.cancel() }
                        }
                        let started = now()
                        var threw = false
                        var op = ""
                        do {
                            if isSearcher {
                                op = "search(absent)"
                                let pattern = try SearchPattern(
                                    "zzz_not_there_" + String(random.next() % 10), options: SearchOptions(),
                                    encoding: document.encoding)
                                let from = Int64(random.next() % UInt64(max(1, document.content.upperBound)))
                                // Bounded: at most 256 MiB from a random place, so one call ends in time.
                                let end = min(document.content.upperBound, from + (256 << 20))
                                if let hit = try ViewerSearch.find(
                                    pattern, in: document.source, content: document.content.lowerBound..<end,
                                    from: from, backwards: random.next() % 4 == 0,
                                    encoding: document.encoding, cancellation: flag)
                                {
                                    fail("\(label): found a text that is not there", "\(hit)")
                                }
                            } else {
                                let count = document.rowCount
                                switch random.next() % 4 {
                                case 0, 1:
                                    op = "rows(from:count:100)"
                                    guard count > 0 else { break }
                                    let first = Int(random.next() % UInt64(count))
                                    let rows = try document.rows(from: first, count: 100, cancellation: flag)
                                    check(rows, first: first, flagCancelled: flag.isCancelled)
                                    if rows.isEmpty, !flag.isCancelled, first < document.rowCount,
                                        document.readError == nil
                                    {
                                        fail(
                                            "\(label): no rows for a known row", "row \(first) of \(document.rowCount)"
                                        )
                                    }
                                case 2:
                                    op = "row(containing:)"
                                    let offset = Int64(random.next() % UInt64(max(1, document.content.upperBound)))
                                    let row = try document.row(containing: offset, cancellation: flag)
                                    if let row, row < 0 || row >= max(1, document.rowCount) {
                                        fail(
                                            "\(label): row(containing:) out of range", "\(row) of \(document.rowCount)"
                                        )
                                    }
                                    if row == nil, document.isIndexComplete, !flag.isCancelled, document.rowCount > 0,
                                        document.readError == nil
                                    {
                                        fail("\(label): no row for an offset of a complete index", "offset \(offset)")
                                    }
                                default:
                                    op = "row(ofLine:)"
                                    let lines = document.lineCount
                                    guard lines > 0 else { break }
                                    let line = 1 + Int(random.next() % UInt64(lines))
                                    let row = try document.row(ofLine: line, cancellation: flag)
                                    if let row, row < 0 || row >= document.rowCount {
                                        fail("\(label): row(ofLine:) out of range", "\(row) of \(document.rowCount)")
                                    }
                                }
                            }
                        } catch {
                            threw = true
                            if !flag.isCancelled, !document.cancellation.isCancelled {
                                fail("\(label): \(op) threw without a cancel", "\(error)")
                            }
                        }
                        if !op.isEmpty { note(op, now() - started, cancelled: flag.isCancelled, threw: threw) }
                    }
                }
                group.leave()
            }
            thread.name = "Stress.Hammer"
            thread.start()
        }
    }

    /// Stops the threads and waits for them (pumping the main run loop). Returns false when
    /// they do not end.
    @discardableResult
    func stop(upTo seconds: Double = 60) -> Bool {
        lock.lock()
        stopped = true
        lock.unlock()
        var done = false
        group.notify(queue: .main) { done = true }
        return pump(upTo: seconds) { done }
    }

    func report() {
        lock.lock()
        let copy = stats
        lock.unlock()
        for (op, s) in copy.sorted(by: { $0.key < $1.key }) {
            say(
                "  " + pad("[\(label)] \(op)", 58)
                    + String(
                        format: " n=%7d mean=%8.3fms max=%9.1fms cancelled=%d threw=%d", s.count,
                        s.total / Double(max(1, s.count)) * 1000, s.maxMs, s.cancelled, s.threw))
        }
    }
}

/// What a user does at the pager, on the main thread, once per tick of the run loop.
let environment = ProcessInfo.processInfo.environment
let noHammer = environment["STRESS_NO_HAMMER"] != nil
let noUser = environment["STRESS_NO_USER"] != nil
let noSearchers = environment["STRESS_NO_SEARCHERS"] != nil

func userAction(_ pager: TextPagerView, _ random: inout Random, mayStop: Bool = false) {
    guard !noUser, let document = pager.document else { return }
    switch random.next() % (mayStop ? 400 : 5) {
    case 0, 1: pager.scroll(toPercent: Double(random.next() % 10_001) / 100)
    case 2: pager.scroll(toLine: 1 + Int(random.next() % UInt64(max(1, document.lineCount))))
    case 3: pager.reveal(offset: Int64(random.next() % UInt64(max(1, document.length))))
    case 4: _ = (pager.percent, pager.position, pager.indexingProgress, pager.isIndexing)
    case 5: pager.stopReading()  // Esc: about once a second
    default: userAction(pager, &random)
    }
}

// MARK: One file through every step

func runFile(_ url: URL, seed: UInt64) {
    var random = Random(seed: seed)
    let name = url.lastPathComponent
    step("idle baseline") { pump(for: 1) }
    let baselineThreads = threadCount()
    say(
        "file \(name): \(((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? -1) bytes; threads at baseline \(baselineThreads)"
    )

    let pager = TextPagerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
    let fit = pager.columnsThatFit
    var source: ByteSource!
    var firstDocument: TextDocument!

    func show(_ layout: TextLayoutOptions, keeping: Bool) -> TextDocument {
        let document = TextDocument(source: source, encoding: .utf8, layout: .text(layout), reusing: pager.document)
        pager.show(document, at: keeping ? pager.topOffset : 0, keepingSelection: keeping, parallel: true)
        return document
    }

    /// Pumps until the pager's document is indexed, telling how far it is every 5 s.
    func waitIndexed(_ document: TextDocument, limit: Double = 900) -> Bool {
        var last = now()
        let started = last
        return pump(upTo: limit) {
            if now() - last > 5 {
                last = now()
                say(
                    String(
                        format: "    ... %.0fs: indexed through %.1f%% (%.0f MiB/s), rows %d, footprint %.0f MB",
                        last - started,
                        Double(document.indexedThrough) / Double(max(1, document.length)) * 100,
                        Double(document.indexedThrough) / 1_048_576 / (last - started), document.rowCount,
                        footprintMB()))
            }
            return document.isIndexComplete && pager.document === document
        }
    }

    step("open, wrap at \(fit) columns: first rows", limit: 900) {
        let started = now()
        source = openSource(url)
        let opened = now() - started
        firstDocument = show(TextLayoutOptions(columns: fit, wordWrap: true), keeping: false)
        let got = pump(upTo: 880) { pager.document === firstDocument && pager.position != nil }
        say(
            String(
                format: "  open %.3fs; first rows on screen after %.3fs (%@); rows known then: %d", opened,
                now() - started, got ? "ok" : "NOT within 880 s", firstDocument.rowCount))
        if !got { fail("\(name): no first rows", "nothing to show within 880 s") }
    }
    step("index to the end (parallel)", limit: 1000) {
        let started = now()
        let done = waitIndexed(firstDocument)
        say(
            String(
                format:
                    "  index %@ after %.3fs more: rows %d, lines %d, checkpoints %d, footprint %.0f MB, read error: %@",
                done ? "complete" : "NOT complete",
                now() - started, firstDocument.rowCount, firstDocument.lineCount, firstDocument.checkpointCount,
                footprintMB(), String(describing: firstDocument.readError)))
        if !done { fail("\(name): index not complete", "not within the limit") }
    }

    step("indexed: rows from 6 threads + user at the pager, 4 s", limit: 300) {
        let hammer = Hammer(firstDocument, columns: fit, label: "indexed")
        hammer.start(threads: 6, searchers: 0, seed: seed)
        let end = now() + 4
        pump(upTo: 10) {
            userAction(pager, &random)
            return now() > end
        }
        if !hammer.stop() { fail("\(name): hammer threads do not end", "after the index was complete") }
        hammer.report()
    }

    step("indexed: first/last rows and round trips", limit: 300) {
        var done = false
        DispatchQueue.global(qos: .userInitiated).async {
            let document = firstDocument!
            let count = document.rowCount
            var probe = Random(seed: seed + 5)
            for round in 0..<300 {
                let row = round == 0 ? 0 : round == 1 ? max(0, count - 1) : Int(probe.next() % UInt64(max(1, count)))
                guard let got = try? document.rows(from: row, count: 2), let first = got.first else {
                    if count > 0 { fail("\(name): round trip: no row", "row \(row) of \(count)") }
                    continue
                }
                if let back = try? document.row(containing: first.range.lowerBound), back != row, !first.range.isEmpty {
                    fail(
                        "\(name): row(containing:) disagrees with rows(from:)",
                        "row \(row) begins at \(first.range.lowerBound), which is said to be in row \(String(describing: back))"
                    )
                }
                if let lineRow = try? document.row(ofLine: first.line) {
                    if lineRow > row {
                        fail(
                            "\(name): row(ofLine:) behind the row of that line",
                            "line \(first.line): row \(lineRow) > \(row)")
                    }
                } else {
                    fail("\(name): row(ofLine:) finds no row", "line \(first.line) of row \(row)")
                }
            }
            if let last = try? document.rows(from: max(0, count - 1), count: 1).first,
                last.range.upperBound != document.content.upperBound
            {
                fail(
                    "\(name): the last row does not end at the end of the file",
                    "\(last.range) vs \(document.content.upperBound)")
            }
            DispatchQueue.main.async { done = true }
        }
        pump(upTo: 280) { done }
    }

    func search(_ text: String, from start: Int64, backwards: Bool = false, cancelAfter: Double? = nil) -> (
        Range<Int64>?, Double
    ) {
        let document = firstDocument!
        let pattern = try! SearchPattern(text, options: SearchOptions(), encoding: document.encoding)
        let cancel = CancellationFlag()
        var result: Range<Int64>??
        let started = now()
        var ended = 0.0
        DispatchQueue.global(qos: .userInitiated).async {
            var lastReport = Date.distantPast
            // As ViewerPane.search: progress to the main queue at most ten times a second.
            let found = try? ViewerSearch.find(
                pattern, in: document.source, content: document.content, from: start, backwards: backwards,
                encoding: document.encoding, parallelism: ProcessInfo.processInfo.activeProcessorCount,
                cancellation: cancel
            ) { _ in
                guard Date().timeIntervalSince(lastReport) > 0.1 else { return }
                lastReport = Date()
                DispatchQueue.main.async {}
            }
            let at = now()
            DispatchQueue.main.async {
                result = .some(found ?? nil)
                ended = at
            }
        }
        if let cancelAfter {
            pump(upTo: cancelAfter) { result != nil }
            cancel.cancel()
        }
        let asked = now()
        if !pump(upTo: 600, until: { result != nil }) { fail("\(name): a search does not end", "\(text)") }
        return (result ?? nil, cancelAfter == nil ? ended - started : max(0, ended - asked))
    }

    var fullSearch = 1.0
    step("search forward: marker at the very end", limit: 700) {
        let (hit, seconds) = search(marker, from: 0)
        fullSearch = seconds
        say(
            String(
                format: "  marker %@ in %.3fs (%.0f MiB/s)", hit.map { "found at \($0.lowerBound)" } ?? "NOT found",
                seconds, Double(firstDocument.length) / 1_048_576 / seconds))
        if name != "sparse4g.txt" && name != "newlines1g.txt",
            hit?.upperBound != firstDocument.length - (name.hasPrefix("dense") ? 1 : 0)
        {
            fail("\(name): the marker at the end was not found where it is", "\(String(describing: hit))")
        }
    }
    step("search backward from the end: absent text", limit: 700) {
        let (hit, seconds) = search("zzz_not_there", from: firstDocument.length, backwards: true)
        say(String(format: "  absent text: %@ in %.3fs", hit == nil ? "not found" : "FOUND", seconds))
        if hit != nil { fail("\(name): found an absent text", "") }
    }
    step("search cancelled at random, 30 times", limit: 700) {
        var worst = 0.0
        for _ in 0..<30 {
            let (_, latency) = search(
                "zzz_not_there", from: 0, cancelAfter: Double(random.next() % 1000) / 1000 * min(fullSearch, 2))
            worst = max(worst, latency)
        }
        say(String(format: "  cancel -> search returned: worst %.1f ms; threads now %d", worst * 1000, threadCount()))
    }

    var relayout: [(String, Double, Int)] = []
    func timedLayout(_ label: String, _ options: TextLayoutOptions) {
        step("relayout: \(label)", limit: 1000) {
            let started = now()
            let document = show(options, keeping: true)
            let done = waitIndexed(document)
            let seconds = now() - started
            relayout.append((label, seconds, document.segmentsReused))
            say(
                String(
                    format:
                        "  %@: %@ in %.3fs, segments reused %d, rows %d, lines %d, checkpoints %d, footprint %.0f MB",
                    label, done ? "complete" : "NOT complete",
                    seconds, document.segmentsReused, document.rowCount, document.lineCount, document.checkpointCount,
                    footprintMB()))
            if !done { fail("\(name): relayout not complete", label) }
            if document.lineCount != firstDocument.lineCount {
                fail(
                    "\(name): another layout counts other lines",
                    "\(label): \(document.lineCount) vs \(firstDocument.lineCount)")
            }
        }
    }
    timedLayout("wider, wrap at \(fit + 23)", TextLayoutOptions(columns: fit + 23, wordWrap: true))
    timedLayout("narrow, wrap at 40", TextLayoutOptions(columns: 40, wordWrap: true))
    timedLayout("no wrap, cut at 1024", TextLayoutOptions(columns: 1024, wordWrap: false))

    // The window dragged wider and narrower while the text is being indexed: every new width
    // drops the layout before. All the while threads read rows and search, and the user scrolls.
    step("storm: 40 relayouts during indexing + 6 readers + 2 searchers + user", limit: 1200) {
        var hammers: [Hammer] = []
        var peakThreads = 0
        for round in 0..<40 {
            let columns = 30 + Int(random.next() % 200)
            let document = show(
                TextLayoutOptions(columns: columns, wordWrap: random.next() % 4 != 0), keeping: random.next() % 2 == 0
            )
            let hammer = Hammer(document, columns: columns, label: "during indexing")
            hammer.start(threads: 6, searchers: round % 4 == 0 ? 2 : 0, seed: seed + UInt64(round))
            hammers.append(hammer)
            let end = now() + Double(random.next() % 400) / 1000
            pump(upTo: 5) {
                userAction(pager, &random, mayStop: true)
                return now() > end
            }
            peakThreads = max(peakThreads, threadCount())
            // The readers of the layout that is replaced go on for a while, as a view's would.
            if hammers.count > 2 {
                let old = hammers.removeFirst()
                if !old.stop() { fail("\(name): hammer threads do not end", "in the storm, round \(round)") }
                if round == 39 || round == 20 { old.report() }
            }
        }
        say("  threads at most during the storm: \(peakThreads)")
        for hammer in hammers where !hammer.stop() {
            fail("\(name): hammer threads do not end", "at the end of the storm")
        }
        hammers.last?.report()
        say(
            String(format: "  footprint at the end of the storm %.0f MB, peak RSS %.0f MB", footprintMB(), peakRSSMB()))
        // One last layout that nobody stops (a layout stopped with Esc stays unfinished by design).
        let last = show(TextLayoutOptions(columns: fit, wordWrap: true), keeping: true)
        let started = now()
        let done = pump(upTo: 900) { !pager.isIndexing }
        say(
            String(
                format: "  the last layout was %@ %.3fs after the storm; shown document is the last one: %@",
                done ? "indexed" : "NOT indexed", now() - started,
                String(describing: last === pager.document)))
        if done, last.lineCount != firstDocument.lineCount || last.rowCount != firstDocument.rowCount {
            fail(
                "\(name): the same layout after the storm has other rows",
                "rows \(last.rowCount) vs \(firstDocument.rowCount), lines \(last.lineCount) vs \(firstDocument.lineCount)"
            )
        }
        if !done { fail("\(name): the last layout of the storm is not indexed", "") }
    }

    step("close; threads settle", limit: 120) {
        pager.clear()
        source.close()
        var trace: [String] = []
        let started = now()
        for _ in 0..<40 {
            trace.append(String(format: "%.1fs:%d", now() - started, threadCount()))
            if threadCount() <= baselineThreads + 2 { break }
            pump(for: 0.5)
        }
        say("  threads after closing: " + trace.joined(separator: " ") + " (baseline \(baselineThreads))")
        if threadCount() > baselineThreads + 4 {
            fail("\(name): threads do not return to the baseline", "\(baselineThreads) -> \(threadCount())")
        }
        say(String(format: "  footprint after closing %.0f MB, peak RSS %.0f MB", footprintMB(), peakRSSMB()))
    }
    say(
        "RELAYOUT "
            + relayout.map { String(format: "%@: %.3fs (reused %d)", $0.0, $0.1, $0.2) }.joined(separator: "; "))
}

// MARK: A file that shrinks under the index

func runTruncation(_ directory: URL, rounds: Int) {
    let url = directory.appendingPathComponent("truncate1g.txt")
    var random = Random(seed: 99)
    step("idle baseline") { pump(for: 1) }
    let baselineThreads = threadCount()
    for round in 0..<rounds {
        step("(harness: writing the 1 GiB file)") { _ = writeDense(url, megabytes: 1024) }
        step("truncate while indexing", limit: 300) {
            let pager = TextPagerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            let source = openSource(url)
            let columns = round % 3 == 2 ? 1024 : pager.columnsThatFit
            let document = TextDocument(
                source: source, encoding: .utf8,
                layout: .text(TextLayoutOptions(columns: columns, wordWrap: round % 3 != 2)))
            pager.show(document, parallel: true)
            let hammer = Hammer(document, columns: columns, label: "truncated")
            hammer.start(threads: 4, searchers: 1, seed: UInt64(round))
            let delay = Double(random.next() % 300) / 1000
            let kind = round % 4
            let cutter = Thread {
                usleep(UInt32(delay * 1_000_000))
                switch kind {
                case 0: truncate(url.path, 300 << 20)
                case 1: truncate(url.path, 0)
                case 2:
                    truncate(url.path, 12345)
                    usleep(20_000)
                    truncate(url.path, 2 << 30)
                default: unlink(url.path)
                }
            }
            cutter.start()
            let started = now()
            let end = now() + 1.5
            pump(upTo: 5) {
                userAction(pager, &random)
                return now() > end
            }
            let done = pump(upTo: 120) { !pager.isIndexing }
            let action = ["cut to 300 MiB", "cut to 0", "cut to 12345 bytes, then grown to 2 GiB", "removed"][kind]
            say(
                String(
                    format:
                        "  round %d: %@ after %.0f ms; indexing %@ %.2fs after the start; rows %d, lines %d, indexed through %d of %d, complete %@, read error: %@",
                    round, action, delay * 1000, done ? "ended" : "DID NOT END", now() - started, document.rowCount,
                    document.lineCount, document.indexedThrough, document.length,
                    String(describing: document.isIndexComplete),
                    document.readError.map { "\($0)".prefix(120).description } ?? "none"))
            if !done { fail("truncation: indexing does not end", action) }
            // The rows the index knows are asked for after the file has shrunk.
            pump(for: 0.3)
            if !hammer.stop() { fail("truncation: hammer threads do not end", action) }
            hammer.report()
            pager.clear()
            source.close()
        }
    }
    step("threads settle") {
        let after = waitForThreads(atMost: baselineThreads + 2, upTo: 15, onMain: true)
        say("  threads: baseline \(baselineThreads), at the end \(after)")
    }
    try? FileManager.default.removeItem(at: url)
}

/// Which call keeps memory: each kind of call 20,000 times from one thread, the footprint after each.
func runLeak(_ url: URL) {
    let source = openSource(url)
    let document = TextDocument(
        source: source, encoding: .utf8, layout: .text(TextLayoutOptions(columns: 131, wordWrap: true)))
    document.buildIndex(parallel: true)
    var random = Random(seed: 3)
    say(String(format: "indexed: rows %d, footprint %.0f MB", document.rowCount, footprintMB()))
    func measure(_ label: String, _ count: Int = 20_000, _ body: (inout Random) -> Void) {
        let before = footprintMB()
        for _ in 0..<count { autoreleasepool { body(&random) } }
        say(
            pad(label, 70)
                + String(
                    format: " footprint %7.0f -> %7.0f MB  (%+.1f KB per call)", before, footprintMB(),
                    (footprintMB() - before) * 1024 / Double(count)))
    }
    let rows = document.rowCount
    let lines = document.lineCount
    let length = document.length
    measure("rows(from:count:100), no flag") {
        _ = try? document.rows(from: Int($0.next() % UInt64(rows)), count: 100)
    }
    measure("rows(from:count:100), flag never set") {
        _ = try? document.rows(from: Int($0.next() % UInt64(rows)), count: 100, cancellation: CancellationFlag())
    }
    measure("rows(from:count:100), flag set before the call") {
        let flag = CancellationFlag()
        flag.cancel()
        _ = try? document.rows(from: Int($0.next() % UInt64(rows)), count: 100, cancellation: flag)
    }
    measure("rows(from:count:100), flag set from another thread during the call") { random in
        let flag = CancellationFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + .microseconds(Int(random.next() % 300))) { flag.cancel() }
        _ = try? document.rows(from: Int(random.next() % UInt64(rows)), count: 100, cancellation: flag)
    }
    measure("row(containing:), no flag") { _ = try? document.row(containing: Int64($0.next() % UInt64(length))) }
    measure("row(containing:), flag never set") {
        _ = try? document.row(containing: Int64($0.next() % UInt64(length)), cancellation: CancellationFlag())
    }
    measure("row(ofLine:), flag never set") {
        _ = try? document.row(ofLine: 1 + Int($0.next() % UInt64(lines)), cancellation: CancellationFlag())
    }
    measure("source.read(at:count:32K), no flag") {
        _ = try? source.read(at: Int64($0.next() % UInt64(length)), count: 32 * 1024)
    }
    measure("source.read(at:count:32K, cancellation:), flag never set") {
        _ = try? source.read(at: Int64($0.next() % UInt64(length)), count: 32 * 1024, cancellation: CancellationFlag())
    }
    let pattern = try! SearchPattern("zzz_not_there", options: SearchOptions(), encoding: .utf8)
    // With one chunk at a time everything runs on the calling thread, inside this loop's autorelease pool.
    measure("ViewerSearch.find over the whole file, parallelism 1 (calling thread only)", 100) { _ in
        _ = try? ViewerSearch.find(
            pattern, in: source, content: document.content, from: 0, backwards: false, encoding: .utf8, parallelism: 1
        )
    }
    measure("ViewerSearch.find over the whole file, flag never set", 100) { _ in
        _ = try? ViewerSearch.find(
            pattern, in: source, content: document.content, from: 0, backwards: false, encoding: .utf8)
    }
    measure("new TextDocument + buildIndex (another width each time)", 100) { random in
        let other = TextDocument(
            source: source, encoding: .utf8,
            layout: .text(TextLayoutOptions(columns: 40 + Int(random.next() % 100), wordWrap: true)))
        other.buildIndex(parallel: true)
    }
    func heapLine(_ label: String) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        say(
            pad(label, 44)
                + String(
                    format:
                        " footprint %6.0f MB; malloc in use %6.0f MB, allocated from the system %6.0f MB; threads %d",
                    footprintMB(),
                    Double(stats.size_in_use) / 1_048_576, Double(stats.size_allocated) / 1_048_576, threadCount()))
    }
    heapLine("right after")
    usleep(5_000_000)
    heapLine("5 s later (pool threads gone)")
    let freed = malloc_zone_pressure_relief(nil, 0)
    heapLine("after malloc_zone_pressure_relief (\(freed >> 20) MB)")
    // Once more, to see whether a second round adds to it or uses what was kept.
    measure("ViewerSearch.find over the whole file, again", 100) { _ in
        _ = try? ViewerSearch.find(
            pattern, in: source, content: document.content, from: 0, backwards: false, encoding: .utf8)
    }
    heapLine("right after the second round")
    usleep(5_000_000)
    heapLine("5 s later")
}

switch arguments[1] {
case "leak":
    runLeak(URL(fileURLWithPath: arguments[2]))
    exit(0)
case "run":
    runFile(URL(fileURLWithPath: arguments[2]), seed: arguments.count > 4 ? UInt64(arguments[4])! : 1)
case "truncate":
    runTruncation(URL(fileURLWithPath: arguments[2]), rounds: arguments.count > 4 ? Int(arguments[4])! : 12)
default:
    say("usage")
    exit(2)
}

if let hold = environment["STRESS_HOLD"].flatMap(Double.init) {
    say("holding for \(hold) s, pid \(getpid()), footprint \(footprintMB()) MB")
    pump(for: hold)
}
MainWatchdog.shared.report(title: "scenario 7, viewer: " + arguments[2])
say("\nFAILURES: \(failures.count) kinds")
failureLock.lock()
for failure in failures { say("  " + failure) }
let counts = failureCounts
failureLock.unlock()
for (kind, count) in counts.sorted(by: { $0.key < $1.key }) { say("  count \(count): \(kind)") }
say(String(format: "peak RSS %.0f MB, threads %d, load %.1f", peakRSSMB(), threadCount(), loadAverage()))
exit(failures.isEmpty ? 0 : 1)
