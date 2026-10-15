import AVKit
import AppKit
import Foundation
import PDFKit
import Quartz
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
        let deadline = Date(timeIntervalSinceNow: 60)
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

    /// A track plays, can be paused, muted, made louder and quieter, moved in, and stopped; at its
    /// end the player says so.
    @Test
    internal func aTrackIsPlayedAndControlled() async throws {
        let directory = try Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tone.wav")
        try CoverageViewerMediaFiles.wav(seconds: 1).write(to: file)
        let view = MediaView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let player = try #require(try Self.playerView(of: view).player)
        var ended = false
        view.onEnd = { ended = true }
        // Silent: the player is muted before it is made louder.
        view.play(file, volume: 0)
        #expect(view.volume == 0 && player.rate > 0)
        view.togglePlaying()
        #expect(player.rate == 0)
        view.togglePlaying()
        #expect(player.rate > 0)
        // Before the track is ready a step is a tenth of a second too.
        let early = MediaView(frame: .zero)
        early.play(file, volume: 0)
        early.step()
        #expect(try #require(try Self.playerView(of: early).player).rate == 0)
        early.stop()
        view.toggleMute()
        #expect(player.isMuted)
        view.changeVolume(by: 0.5)
        #expect(view.volume == 0.5)
        view.changeVolume(by: 0.8)
        #expect(view.volume == 1)
        view.changeVolume(by: -2)
        #expect(view.volume == 0)
        view.seek(by: 0.5)
        #expect(await Self.wait { player.currentTime().seconds >= 0.5 })
        // A step goes on a little and pauses.
        #expect(await Self.wait { player.currentItem?.status == .readyToPlay })
        let before = player.currentTime().seconds
        view.step()
        #expect(await Self.wait { player.currentTime().seconds >= before } && player.rate == 0)
        view.togglePlaying()
        #expect(await Self.wait { ended })
        view.stop()
        #expect(player.currentItem == nil)
        // Without a track a step does nothing.
        view.step()
        #expect(player.currentItem == nil)
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
        let view = MediaView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var titles: [String] = []
        view.onTitle = { titles.append($0) }
        view.play(both, volume: 0)
        #expect(await Self.wait { titles == ["Song – Band"] })
        view.play(titleOnly, volume: 0)
        #expect(await Self.wait { titles == ["Song – Band", "Alone"] })
        let untagged = directory.appendingPathComponent("plain.wav")
        try CoverageViewerMediaFiles.wav(seconds: 0.2).write(to: untagged)
        let quiet = MediaView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        // The player that tells nothing to anyone: what it would tell goes nowhere.
        quiet.play(untagged, volume: 0)
        quiet.play(directory.appendingPathComponent("missing.wav"), volume: 0)
        let ended = ViewerAdoptBox(false)
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { _ in ended.value = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        quiet.play(untagged, volume: 0)
        #expect(await Self.wait { ended.value })
        #expect(titles.count == 2)
        view.stop()
        quiet.stop()
    }

    /// A film goes on by one frame at a time; F fits it to the window or fills the window.
    @Test
    internal func aFilmStepsByFrames() async throws {
        let directory = try Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let film = directory.appendingPathComponent("film.mov")
        try CoverageViewerMediaFiles.film(at: film, frames: 10)
        let view = MediaView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let playerView = try Self.playerView(of: view)
        let player = try #require(playerView.player)
        view.play(film, volume: 0)
        #expect(await Self.wait { player.currentItem?.status == .readyToPlay })
        view.togglePlaying()
        view.seek(by: -10)
        #expect(await Self.wait { player.currentTime().seconds == 0 })
        view.step()
        #expect(await Self.wait { player.currentTime().seconds > 0 })
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
