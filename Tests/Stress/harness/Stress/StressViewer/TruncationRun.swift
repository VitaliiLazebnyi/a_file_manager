import AFMKernel
import CoreGraphics
import Foundation
import StressKit

@testable import ViewerPlugin

/// A file that shrinks under the index: cut short, cut to nothing, cut and grown, or removed while it
/// is being indexed, read and searched.
@MainActor
internal enum TruncationRun {
    /// What happens to the file, by round modulo 4.
    private static let actions = ["cut to 300 MiB", "cut to 0", "cut to 12345 bytes, then grown to 2 GiB", "removed"]

    /// `rounds` rounds on a 1 GiB file written into `directory`, then the threads have to settle.
    internal static func run(_ directory: URL, rounds: Int, fileSystems: FileSystemRegistry) {
        let url = directory.appendingPathComponent("truncate1g.txt")
        var random = Random(seed: 99)
        step("idle baseline") { pump(for: 1) }
        let baselineThreads = threadCount()
        for round in 0..<rounds {
            step("(harness: writing the 1 GiB file)") { ViewerFiles.writeDense(url, megabytes: 1_024) }
            step("truncate while indexing", limit: 300) {
                oneRound(round, url: url, fileSystems: fileSystems, random: &random)
            }
        }
        step("threads settle") {
            let after = waitForThreads(atMost: baselineThreads + 2, upTo: 15)
            say("  threads: baseline \(baselineThreads), at the end \(after)")
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// One round: the file shown, hammered and cut after a random moment.
    private static func oneRound(_ round: Int, url: URL, fileSystems: FileSystemRegistry, random: inout Random) {
        let pager = TextPagerView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 700))
        let source = Harness.openSource(url, fileSystems: fileSystems)
        let columns = round % 3 == 2 ? 1_024 : pager.columnsThatFit
        let document = TextDocument(
            source: source,
            encoding: .utf8,
            bomLength: 0,
            layout: .text(TextLayoutOptions(columns: columns, wordWrap: round % 3 != 2, tabWidth: 8)),
            reusing: nil
        )
        pager.show(document, parallel: true)
        let hammer = Hammer(document, columns: columns, label: "truncated")
        hammer.start(threads: 4, searchers: 1, seed: UInt64(round))
        let delay = Double(random.next() % 300) / 1_000
        let kind = round % 4
        let cutter = Thread {
            cut(url.path, kind: kind, after: delay)
        }
        cutter.start()
        let started = now()
        let end = now() + 1.5
        pump(upTo: 5) {
            Harness.userAction(pager, &random, mayStop: false)
            return now() > end
        }
        let done = pump(upTo: 120) { !pager.isIndexing }
        let action = actions[kind]
        say(
            String(
                format: "  round %d: %@ after %.0f ms; indexing %@ %.2fs after the start; %@",
                round,
                action,
                delay * 1_000,
                done ? "ended" : "DID NOT END",
                now() - started,
                describe(document)
            )
        )
        if !done {
            fail("truncation: indexing does not end", action)
        }
        // The rows the index knows are asked for after the file has shrunk.
        pump(for: 0.3)
        if !hammer.stop() {
            fail("truncation: hammer threads do not end", action)
        }
        hammer.report()
        pager.clear()
        source.close()
    }

    /// How far the index of `document` got, and why it stopped.
    private static func describe(_ document: TextDocument) -> String {
        String(
            format: "rows %d, lines %d, indexed through %d of %d, complete %@, read error: %@",
            document.rowCount,
            document.lineCount,
            document.indexedThrough,
            document.length,
            String(describing: document.isIndexComplete),
            document.readError.map { "\($0)".prefix(120).description } ?? "none"
        )
    }

    /// Waits `delay` seconds, then does to the file at `path` what round kind `kind` does.
    nonisolated private static func cut(_ path: String, kind: Int, after delay: Double) {
        usleep(UInt32(delay * 1_000_000))
        switch kind {
        case 0:
            truncate(path, 300 << 20)

        case 1:
            truncate(path, 0)

        case 2:
            truncate(path, 12_345)
            usleep(20_000)
            truncate(path, 2 << 30)

        default:
            unlink(path)
        }
    }
}
