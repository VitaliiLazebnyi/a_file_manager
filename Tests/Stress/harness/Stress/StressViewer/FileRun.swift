import AFMKernel
import AppKit
import Foundation
import StressKit

@testable import ViewerPlugin

/// One file through every step: open, index, rows from many threads, searches, relayouts, a storm of
/// relayouts while indexing, close.
@MainActor
internal final class FileRun {
    /// The file.
    internal let url: URL
    /// Its name, in failures.
    internal let name: String
    /// The seed of the run.
    internal let seed: UInt64
    /// Where the file is opened.
    internal let fileSystems: FileSystemRegistry
    /// Threads in the process before the file was opened.
    internal let baselineThreads: Int
    /// The pager the file is shown in, without a window.
    internal let pager = TextPagerView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 700))
    /// The columns that fit the pager.
    internal let fit: Int
    /// What the user and the storm do.
    internal var random: Random
    /// How long a search through the whole file took.
    internal var fullSearch = 1.0
    /// The timed relayouts, for the RELAYOUT line.
    internal var relayouts: [Relayout] = []
    /// The file's bytes, once opened.
    private var openedSource: (any ByteSource)?
    /// The first layout of the file, once shown.
    private var openedDocument: TextDocument?

    /// The file's bytes; the file is opened in the first step.
    internal var source: any ByteSource {
        guard let openedSource else {
            preconditionFailure("the file is not open yet")
        }
        return openedSource
    }

    /// The first layout of the file; shown in the first step.
    internal var firstDocument: TextDocument {
        guard let openedDocument else {
            preconditionFailure("the file is not shown yet")
        }
        return openedDocument
    }

    /// A run of `url` with `seed`, after the process had `baselineThreads` threads.
    private init(_ url: URL, seed: UInt64, fileSystems: FileSystemRegistry, baselineThreads: Int) {
        self.url = url
        name = url.lastPathComponent
        self.seed = seed
        self.fileSystems = fileSystems
        self.baselineThreads = baselineThreads
        random = Random(seed: seed)
        fit = pager.columnsThatFit
    }

    /// Takes `url` through every step.
    internal static func run(_ url: URL, seed: UInt64, fileSystems: FileSystemRegistry) {
        step("idle baseline") { pump(for: 1) }
        let threadsBefore = threadCount()
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? -1
        say("file \(url.lastPathComponent): \(size) bytes; threads at baseline \(threadsBefore)")
        let fileRun = FileRun(url, seed: seed, fileSystems: fileSystems, baselineThreads: threadsBefore)
        fileRun.everyStep()
    }

    /// Searches `document` for `text` on this thread with every core; nil when not found or cancelled.
    nonisolated private static func find(
        _ text: String,
        in document: TextDocument,
        from start: Int64,
        backwards: Bool,
        cancel: CancellationFlag
    ) -> Range<Int64>? {
        let pattern: SearchPattern
        do {
            pattern = try SearchPattern(text, options: SearchOptions(), encoding: document.encoding)
        } catch {
            preconditionFailure("not a pattern: \(text): \(error)")
        }
        var lastReport = Date.distantPast
        // As ViewerPane.search: progress to the main queue at most ten times a second.
        return try? ViewerSearch.find(
            pattern,
            in: document.source,
            content: document.content,
            from: start,
            backwards: backwards,
            encoding: document.encoding,
            parallelism: ProcessInfo.processInfo.activeProcessorCount,
            cancellation: cancel
        ) { _ in
            guard Date().timeIntervalSince(lastReport) > 0.1 else {
                return
            }
            lastReport = Date()
            DispatchQueue.main.async {
                // Only the hop to the main queue, as a progress report makes.
            }
        }
    }

    /// Shows a new document of the source in `layout`, at the place shown before when `keeping`.
    internal func show(_ layout: TextLayoutOptions, keeping: Bool) -> TextDocument {
        let document = TextDocument(source: source, encoding: .utf8, layout: .text(layout), reusing: pager.document)
        pager.show(document, at: keeping ? pager.topOffset : 0, keepingSelection: keeping, parallel: true)
        return document
    }

    /// Pumps until the pager's document is indexed, telling how far it is every 5 s; false after 900 s.
    internal func waitIndexed(_ document: TextDocument) -> Bool {
        var last = now()
        let started = last
        return pump(upTo: 900) {
            if now() - last > 5 {
                last = now()
                say(
                    String(
                        format: "    ... %.0fs: indexed through %.1f%% (%.0f MiB/s), rows %d, footprint %.0f MB",
                        last - started,
                        Double(document.indexedThrough) / Double(max(1, document.length)) * 100,
                        Double(document.indexedThrough) / 1_048_576 / (last - started),
                        document.rowCount,
                        footprintMB()
                    )
                )
            }
            return document.isIndexComplete && pager.document === document
        }
    }

    /// Searches the first document for `text` in the background, as ViewerPane does, cancelled after
    /// `cancelAfter` seconds when given; the hit and how long the search took (or, cancelled, how long
    /// it took to return after the cancel).
    internal func search(_ text: String, from start: Int64, backwards: Bool, cancelAfter: Double?) -> (
        Range<Int64>?, Double
    ) {
        let document = firstDocument
        let cancel = CancellationFlag()
        let result = Shared<(Range<Int64>?, Double)?>(nil)
        let started = now()
        DispatchQueue.global(qos: .userInitiated)
            .async {
                let found = Self.find(text, in: document, from: start, backwards: backwards, cancel: cancel)
                let endedAt = now()
                DispatchQueue.main.async { result.value = (found, endedAt) }
            }
        if let cancelAfter {
            pump(upTo: cancelAfter) { result.value != nil }
            cancel.cancel()
        }
        let asked = now()
        if !pump(upTo: 600, until: { result.value != nil }) {
            fail("\(name): a search does not end", "\(text)")
        }
        let ended = result.value?.1 ?? 0
        return (result.value?.0, cancelAfter == nil ? ended - started : max(0, ended - asked))
    }

    /// Opens the file and shows its first layout; how long until the first rows are on screen.
    internal func open() {
        step("open, wrap at \(fit) columns: first rows", limit: 900) {
            let started = now()
            openedSource = Harness.openSource(url, fileSystems: fileSystems)
            let opened = now() - started
            let document = show(TextLayoutOptions(columns: fit, wordWrap: true), keeping: false)
            openedDocument = document
            let got = pump(upTo: 880) { pager.document === document && pager.position != nil }
            say(
                String(
                    format: "  open %.3fs; first rows on screen after %.3fs (%@); rows known then: %d",
                    opened,
                    now() - started,
                    got ? "ok" : "NOT within 880 s",
                    document.rowCount
                )
            )
            if !got {
                fail("\(name): no first rows", "nothing to show within 880 s")
            }
        }
    }

    /// Every step, in order, and the RELAYOUT line.
    private func everyStep() {
        open()
        indexToTheEnd()
        hammerIndexed()
        roundTrips()
        searchMarker()
        searchAbsent()
        searchCancelled()
        timedLayout("wider, wrap at \(fit + 23)", TextLayoutOptions(columns: fit + 23, wordWrap: true))
        timedLayout("narrow, wrap at 40", TextLayoutOptions(columns: 40, wordWrap: true))
        timedLayout("no wrap, cut at 1024", TextLayoutOptions(columns: 1_024, wordWrap: false))
        storm()
        close()
        let lines = relayouts.map { String(format: "%@: %.3fs (reused %d)", $0.label, $0.seconds, $0.reused) }
        say("RELAYOUT " + lines.joined(separator: "; "))
    }

    deinit {
        // Nothing to release.
    }
}
