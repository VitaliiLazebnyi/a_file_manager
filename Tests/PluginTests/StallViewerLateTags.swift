import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The text of an HTML file whose tags were removed comes back to the main thread late: another mode was chosen
/// meanwhile.
///
/// The pane's work queue runs the removal; a barrier on it waits until that is done and its answer
/// waits for the main thread, which this test holds until it has chosen the other mode.
@MainActor
@Suite(.serialized)
internal struct StallViewerLateTags {
    /// A file system `stallview` that serves `held` as each of its files.
    private static func serve(_ held: CoverageViewerHeldSource, _ bench: CoverageViewerPaneBench) {
        let provider = CoverageViewerProvider(
            scheme: "stallview",
            entry: { url in
                FileItem(url: url, name: url.lastPathComponent, kind: .init(), stat: .init(size: held.length))
            },
            reader: { _ in CoverageViewerSourceReader(held) }
        )
        bench.setup.bench.kernel.fileSystems.register(provider)
    }

    /// The tags were removed and the text waits for the main thread, which shows the file as text first: the
    /// removed text is dropped, and choosing the HTML mode again removes the tags again.
    @Test
    internal func textWhoseModeWasLeftBeforeItArrivedIsDropped() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        bench.setup.bench.kernel.settings.set(false, forKey: "viewer.htmlAsText")
        Self.serve(CoverageViewerHeldSource("<p>A <a href=\"x.html\">link</a></p>"), bench)
        let url = try #require(URL(string: "stallview:///page.html"))
        let pane = try #require(await bench.open(url))
        #expect(await bench.textShown(pane))
        pane.setMode(.html)
        pane.workQueue.sync(flags: .barrier) {
            // The tags have been removed; the text is on its way to the main thread.
        }
        pane.setMode(.text)
        await CoverageViewerPagerBench.settleAlone()
        #expect(pane.mode == .text && pane.failure == nil)
        // Nothing of the dropped text was kept: the HTML mode starts over.
        pane.setMode(.html)
        #expect(pane.htmlLinks.isEmpty)
        #expect(await bench.wait { pane.htmlLinks == ["x.html"] })
    }
}
