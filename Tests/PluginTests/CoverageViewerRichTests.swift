import AVKit
import AppKit
import Foundation
import PDFKit
import Quartz
import TestSupport
import Testing
import WebKit

@testable import ViewerPlugin

/// The views of the rich modes: the player, the web page and its links, the text and PDF views
/// and Quick Look.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerRichTests {
    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "afm-cov-rich-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func wait(until condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: Wait.ceiling)
        while !condition() {
            if Date() > deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    private static func playerView(of view: MediaView) throws -> AVPlayerView {
        try #require(view.subviews.compactMap { $0 as? AVPlayerView }.first)
    }

    // MARK: The player

    /// A view that plays with a recording player, and that player.
    private static func mediaView() throws -> (view: MediaView, playback: CovViewPlayback) {
        let view = MediaView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), playback: CovViewPlayback())
        return (view, try #require(view.playback as? CovViewPlayback))
    }

    /// A track plays, can be paused, muted, made louder and quieter, moved in, and stopped; at its
    /// end the player says so.
    @Test
    internal func aTrackIsPlayedAndControlled() throws {
        let (view, playback) = try Self.mediaView()
        // The controls on screen drive the player (the recording one has none).
        #expect(try Self.playerView(of: view).player == nil)
        var ended = false
        view.onEnd = { ended = true }
        let file = URL(fileURLWithPath: "/tmp/tone.wav")
        view.play(file, volume: 0.25)
        #expect(playback.loaded == [file] && playback.isPlaying && view.volume == 0.25)
        view.togglePlaying()
        #expect(!playback.isPlaying)
        view.togglePlaying()
        #expect(playback.isPlaying)
        view.toggleMute()
        #expect(playback.isMuted)
        view.toggleMute()
        #expect(!playback.isMuted)
        view.changeVolume(by: 0.5)
        #expect(view.volume == 0.75)
        view.changeVolume(by: 0.8)
        #expect(view.volume == 1)
        view.changeVolume(by: -2)
        #expect(view.volume == 0)
        // Moving goes from where the track is, never before its start.
        view.seek(by: 0.5)
        #expect(playback.currentSeconds == 0.5)
        view.seek(by: -10)
        #expect(playback.currentSeconds == 0)
        // A sound does not go on by frames: a step is a tenth of a second, and pauses.
        view.step()
        #expect(playback.currentSeconds == 0.1 && !playback.isPlaying)
        playback.finish()
        #expect(ended)
        view.stop()
        #expect(!playback.hasItem && playback.calls.suffix(2) == ["pause", "unload"])
        // Without a track a step does nothing but pause.
        view.step()
        #expect(playback.calls.last == "pause" && playback.currentSeconds == 0.1)
    }

    /// The tags of a track name it, with the artist when there is one; a file without tags or
    /// one that cannot be read names nothing.
    @Test
    internal func tracksNameThemselves() async throws {
        let directory = try Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let both = directory.appendingPathComponent("both.mov")
        let titleOnly = directory.appendingPathComponent("title.mov")
        try CoverageViewerMediaFiles.taggedSound(at: both, title: "Song", artist: "Band")
        try CoverageViewerMediaFiles.taggedSound(at: titleOnly, title: "Alone", artist: nil)
        let (view, _) = try Self.mediaView()
        var titles: [String] = []
        view.onTitle = { titles.append($0) }
        view.play(both, volume: 0)
        #expect(await Self.wait { titles == ["Song – Band"] })
        view.play(titleOnly, volume: 0)
        #expect(await Self.wait { titles == ["Song – Band", "Alone"] })
        let untagged = directory.appendingPathComponent("plain.wav")
        try CoverageViewerMediaFiles.wav(seconds: 0.2).write(to: untagged)
        // The player that tells nothing to anyone: what it would tell goes nowhere.
        let (quiet, quietPlayback) = try Self.mediaView()
        quiet.play(directory.appendingPathComponent("missing.wav"), volume: 0)
        quiet.play(untagged, volume: 0)
        quietPlayback.finish()
        // A third file with tags, read after the two without: only its name comes.
        view.play(both, volume: 0)
        #expect(await Self.wait { titles.count == 3 })
        #expect(titles == ["Song – Band", "Alone", "Song – Band"])
        view.stop()
        quiet.stop()
    }

    /// A film goes on by one frame at a time; F fits it to the window or fills the window.
    @Test
    internal func aFilmStepsByFrames() throws {
        let (view, playback) = try Self.mediaView()
        let playerView = try Self.playerView(of: view)
        view.play(URL(fileURLWithPath: "/tmp/film.mov"), volume: 0)
        playback.canStepForward = true
        view.step()
        #expect(playback.calls.suffix(2) == ["pause", "step"] && playback.currentSeconds > 0)
        let gravity = playerView.videoGravity
        view.toggleFit()
        #expect(playerView.videoGravity != gravity)
        view.toggleFit()
        #expect(playerView.videoGravity == gravity)
        view.stop()
    }

    // MARK: Web pages

    /// The page itself is loaded once; a link that is clicked is handed on, a jump within the
    /// page stays, and every other navigation is refused.
    @Test
    internal func pagesFollowNoLinksThemselves() async throws {
        let view = WebContentView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var links: [URL] = []
        view.onLink = { links.append($0) }
        let web = try #require(view.subviews.compactMap { $0 as? WKWebView }.first)
        view.show(html: "<p>Page</p>")
        #expect(await Self.wait { !web.isLoading && web.estimatedProgress >= 1 })
        // The page was let in: a second load of it is not.
        let blank = URL(string: "about:blank")
        #expect(view.policy(isMainFrame: true, isLinkClick: false, url: blank) == .cancel)
        let page = try #require(URL(string: "https://example.com/page"))
        #expect(view.policy(isMainFrame: true, isLinkClick: true, url: page) == .cancel)
        #expect(view.policy(isMainFrame: true, isLinkClick: true, url: URL(string: "about:blank#part")) == .allow)
        #expect(view.policy(isMainFrame: false, isLinkClick: true, url: nil) == .cancel)
        #expect(links == [page])
        // A new page is let in once more; without a listener a clicked link goes nowhere.
        let silent = WebContentView(frame: .zero)
        silent.show(html: "<p>Other</p>")
        #expect(silent.policy(isMainFrame: true, isLinkClick: false, url: nil) == .allow)
        #expect(silent.policy(isMainFrame: true, isLinkClick: true, url: page) == .cancel)
        #expect(view.printOperation(with: NSPrintInfo()).printInfo.paperSize.width > 0)
    }

    // MARK: Links

    /// A link that cannot be read as a URL leads nowhere.
    @Test
    internal func linksThatAreNoURLsLeadNowhere() throws {
        let base = try #require(URL(string: "file:///tmp/folder/page.html"))
        // What is left of it once the page's own name is taken away is no URL.
        let link = try #require(URL(string: "about:blank//[::1"))
        #expect(LinkPolicy.target(of: link, relativeTo: base) == nil)
    }

    /// The text and PDF views open web links through their gate and nothing else, whatever form
    /// the link comes in.
    @Test
    internal func theGateOpensWebLinksOnly() throws {
        let links = CoverageViewerLinks()
        let gate = LinkGate(opener: links)
        let text = RichViews.textView(NSAttributedString(string: "text")).text
        #expect(gate.textView(text, clickedOnLink: "https://a.example", at: 0))
        #expect(gate.textView(text, clickedOnLink: try #require(URL(string: "https://b.example")), at: 0))
        #expect(gate.textView(text, clickedOnLink: 42, at: 0))
        #expect(gate.textView(text, clickedOnLink: "file:///etc/passwd", at: 0))
        gate.pdfViewWillClick(onLink: PDFView(), with: try #require(URL(string: "mailto:a@example.com")))
        #expect(
            links.opened.map(\.absoluteString) == ["https://a.example", "https://b.example", "mailto:a@example.com"]
        )
        #expect(!text.isEditable && text.string == "text" && text.enclosingScrollView != nil)
    }

    /// Quick Look shows a file, and starts by itself (in a window: closing one outside a window
    /// ends the program).
    @Test
    internal func quickLookShowsAFile() throws {
        let file = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        let view = try #require(RichViews.quickLookView(file))
        #expect(view.previewItem?.previewItemURL == file && view.autostarts)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.close()
    }
}
