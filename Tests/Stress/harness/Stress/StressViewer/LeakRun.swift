import AFMKernel
import Foundation
import StressKit

@testable import ViewerPlugin

/// Which call keeps memory: each kind of call 20,000 times from one thread, the footprint after each.
@MainActor
internal final class LeakRun {
    /// The file's bytes.
    private let source: any ByteSource
    /// The file laid out at 131 columns, indexed.
    private let document: TextDocument
    /// A text the file does not have.
    private let pattern: SearchPattern
    /// The rows of the document.
    private let rows: Int
    /// The lines of the document.
    private let lines: Int
    /// The bytes of the document.
    private let length: Int64
    /// Where the calls go.
    private var random = Random(seed: 3)

    /// Opens and indexes `url`.
    private init(_ url: URL, fileSystems: FileSystemRegistry) {
        source = Harness.openSource(url, fileSystems: fileSystems)
        document = TextDocument(
            source: source,
            encoding: .utf8,
            bomLength: 0,
            layout: .text(TextLayoutOptions(columns: 131, wordWrap: true, tabWidth: 8)),
            reusing: nil
        )
        document.buildIndex(parallel: true, scanning: .standard) {
            // No progress is wanted.
        }
        do {
            pattern = try SearchPattern("zzz_not_there", options: SearchOptions(), encoding: .utf8)
        } catch {
            preconditionFailure("not a pattern: \(error)")
        }
        rows = document.rowCount
        lines = document.lineCount
        length = document.length
    }

    /// Measures every kind of call on `url`.
    internal static func run(_ url: URL, fileSystems: FileSystemRegistry) {
        let leak = LeakRun(url, fileSystems: fileSystems)
        say(String(format: "indexed: rows %d, footprint %.0f MB", leak.rows, footprintMB()))
        leak.measureRows()
        leak.measureLookups()
        leak.measureSearches()
        leak.measureHeap()
    }

    /// Calls `body` `count` times, each in an autorelease pool, and prints the footprint before and after.
    private func measure(_ label: String, count: Int, _ body: (inout Random) -> Void) {
        let before = footprintMB()
        var generator = random
        for _ in 0..<count {
            autoreleasepool { body(&generator) }
        }
        random = generator
        say(
            pad(label, 70)
                + String(
                    format: " footprint %7.0f -> %7.0f MB  (%+.1f KB per call)",
                    before,
                    footprintMB(),
                    (footprintMB() - before) * 1_024 / Double(count)
                )
        )
    }

    /// rows(from:count:) with and without a flag, and with one set before or during the call.
    private func measureRows() {
        measure("rows(from:count:100), no flag", count: 20_000) { random in
            _ = try? document.rows(from: Int(random.next() % UInt64(rows)), count: 100, cancellation: nil)
        }
        measure("rows(from:count:100), flag never set", count: 20_000) { random in
            _ = try? document.rows(
                from: Int(random.next() % UInt64(rows)),
                count: 100,
                cancellation: CancellationFlag()
            )
        }
        measure("rows(from:count:100), flag set before the call", count: 20_000) { random in
            let flag = CancellationFlag()
            flag.cancel()
            _ = try? document.rows(from: Int(random.next() % UInt64(rows)), count: 100, cancellation: flag)
        }
        measure("rows(from:count:100), flag set from another thread during the call", count: 20_000) { random in
            let flag = CancellationFlag()
            DispatchQueue.global()
                .asyncAfter(deadline: .now() + .microseconds(Int(random.next() % 300))) {
                    flag.cancel()
                }
            _ = try? document.rows(from: Int(random.next() % UInt64(rows)), count: 100, cancellation: flag)
        }
    }

    /// row(containing:), row(ofLine:) and reads of the source.
    private func measureLookups() {
        measure("row(containing:), no flag", count: 20_000) { random in
            _ = try? document.row(containing: Int64(random.next() % UInt64(length)), cancellation: nil)
        }
        measure("row(containing:), flag never set", count: 20_000) { random in
            _ = try? document.row(containing: Int64(random.next() % UInt64(length)), cancellation: CancellationFlag())
        }
        measure("row(ofLine:), flag never set", count: 20_000) { random in
            _ = try? document.row(ofLine: 1 + Int(random.next() % UInt64(lines)), cancellation: CancellationFlag())
        }
        measure("source.read(at:count:32K), no flag", count: 20_000) { random in
            _ = try? source.read(at: Int64(random.next() % UInt64(length)), count: 32 * 1_024)
        }
        measure("source.read(at:count:32K, cancellation:), flag never set", count: 20_000) { random in
            _ = try? source.read(
                at: Int64(random.next() % UInt64(length)),
                count: 32 * 1_024,
                cancellation: CancellationFlag()
            )
        }
    }

    /// Searches through the whole file, and new layouts of it.
    private func measureSearches() {
        // With one chunk at a time everything runs on the calling thread, inside this loop's autorelease pool.
        measure("ViewerSearch.find over the whole file, parallelism 1 (calling thread only)", count: 100) { _ in
            _ = try? ViewerSearch.find(
                ViewerSearch.Request(pattern: pattern, start: 0, backwards: false),
                in: ViewerSearch.Subject(source: source, content: document.content, encoding: .utf8, boundaries: nil),
                tuning: ViewerSearch.Tuning(chunkSize: 1 << 20, parallelism: 1, rawBytes: true),
                cancellation: CancellationFlag()
            ) { _ in
                // No progress is wanted.
            }
        }
        measure("ViewerSearch.find over the whole file, flag never set", count: 100) { _ in
            searchWholeFile()
        }
        measure("new TextDocument + buildIndex (another width each time)", count: 100) { random in
            let other = TextDocument(
                source: source,
                encoding: .utf8,
                bomLength: 0,
                layout: .text(TextLayoutOptions(columns: 40 + Int(random.next() % 100), wordWrap: true, tabWidth: 8)),
                reusing: nil
            )
            other.buildIndex(parallel: true, scanning: .standard) {
                // No progress is wanted.
            }
        }
    }

    /// What the heap keeps after the searches, a while later, after a pressure relief, and after another round.
    private func measureHeap() {
        heapLine("right after")
        usleep(5_000_000)
        heapLine("5 s later (pool threads gone)")
        let freed = malloc_zone_pressure_relief(nil, 0)
        heapLine("after malloc_zone_pressure_relief (\(freed >> 20) MB)")
        // Once more, to see whether a second round adds to it or uses what was kept.
        measure("ViewerSearch.find over the whole file, again", count: 100) { _ in
            searchWholeFile()
        }
        heapLine("right after the second round")
        usleep(5_000_000)
        heapLine("5 s later")
    }

    /// One search for the absent text through the whole file, with every core.
    private func searchWholeFile() {
        _ = try? ViewerSearch.find(
            ViewerSearch.Request(pattern: pattern, start: 0, backwards: false),
            in: ViewerSearch.Subject(source: source, content: document.content, encoding: .utf8, boundaries: nil),
            tuning: .standard,
            cancellation: CancellationFlag()
        ) { _ in
            // No progress is wanted.
        }
    }

    /// The footprint, the heap and the threads now.
    private func heapLine(_ label: String) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        say(
            pad(label, 44)
                + String(
                    format:
                        " footprint %6.0f MB; malloc in use %6.0f MB, allocated from the system %6.0f MB; threads %d",
                    footprintMB(),
                    Double(stats.size_in_use) / 1_048_576,
                    Double(stats.size_allocated) / 1_048_576,
                    threadCount()
                )
        )
    }

    deinit {
        // Nothing to release.
    }
}
