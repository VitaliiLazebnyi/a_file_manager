import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The rules for links in a viewed file and in a page, the code pages offered, and folders counted on a server.
extension Review2ViewerSourceTests {
    // MARK: Links

    /// Only web and mail links are handed to the browser; files, servers, scripts and other schemes are not.
    @Test
    internal func onlyWebAndMailLinksOpenInTheBrowser() throws {
        for text in ["https://example.com/a", "http://example.com", "mailto:a@example.com"] {
            #expect(LinkPolicy.opensInBrowser(try #require(URL(string: text))), "\(text)")
        }
        for text in [
            "file:///Applications/Calculator.app", "smb://evil/share", "sftp://evil/x", "ftp://evil/x",
            "x-evil-scheme://run", "javascript:alert(1)", "tel:123", "relative.html"
        ] {
            #expect(!LinkPolicy.opensInBrowser(try #require(URL(string: text))), "\(text)")
        }
    }

    /// A link in a page leads only to a file beside or below it, on the same file system and host.
    @Test
    internal func aPageCanOnlyLeadToFilesBesideTheOneShown() throws {
        let base = URL(fileURLWithPath: "/Users/me/pages/index.html")
        func target(_ text: String) throws -> String? {
            LinkPolicy.target(of: try #require(URL(string: text)), relativeTo: base)?.path
        }
        #expect(try target("other.html") == "/Users/me/pages/other.html")
        #expect(try target("sub/page.html#part") == "/Users/me/pages/sub/page.html")
        for text in [
            "../secret.html", "../../etc/passwd", "file:///etc/passwd", "file:///Users/me/other/x.html",
            "sftp://evil/x", "ftp://evil/x", "smb://evil/x",
            "http://evil/x", "..%2F..%2Fx", "sub/..%2F..%2Fx", "/etc/passwd", "//evil/x"
        ] {
            let found = try target(text)
            #expect(found == nil, "\(text) -> \(found ?? "nil")")
        }
        // The same file system and host only.
        let remote = try #require(URL(string: "sftp://host/pub/doc/index.html"))
        func remoteTarget(_ text: String) throws -> String? {
            LinkPolicy.target(of: try #require(URL(string: text)), relativeTo: remote)?.absoluteString
        }
        #expect(try remoteTarget("next.html") == "sftp://host/pub/doc/next.html")
        for text in ["sftp://other/pub/doc/next.html", "ftp://host/pub/doc/next.html", "../up.html"] {
            #expect(try remoteTarget(text) == nil, "\(text)")
        }
    }

    /// A page shown from a string loads itself once and goes nowhere else; a click is handed on, a
    /// jump inside the page stays.
    @Test
    internal func aPageShownFromAStringNavigatesOnceAndThenNowhere() {
        let blank = URL(string: "about:blank")
        typealias Page = WebContentView
        // The load of the page itself, once.
        #expect(Page.decide(isMainFrame: true, isLinkClick: false, url: blank, expectsPage: true) == .allow)
        // A meta refresh, a redirect, a script-less load of the web or of a file, a frame: refused.
        for text in ["https://evil.example/x", "http://127.0.0.1:18473/refresh", "file:///etc/passwd", "ftp://evil/x"] {
            #expect(
                Page.decide(isMainFrame: true, isLinkClick: false, url: URL(string: text), expectsPage: false)
                    == .cancel,
                "\(text)"
            )
            #expect(
                Page.decide(isMainFrame: true, isLinkClick: false, url: URL(string: text), expectsPage: true)
                    == .cancel,
                "\(text)"
            )
        }
        #expect(Page.decide(isMainFrame: true, isLinkClick: false, url: nil, expectsPage: true) == .allow)
        #expect(Page.decide(isMainFrame: true, isLinkClick: false, url: blank, expectsPage: false) == .cancel)
        #expect(Page.decide(isMainFrame: false, isLinkClick: false, url: blank, expectsPage: true) == .cancel)
        // A click is handed on, and a jump inside the page stays.
        #expect(
            Page.decide(
                isMainFrame: true,
                isLinkClick: true,
                url: URL(string: "https://example.com"),
                expectsPage: false
            )
                == .followLink
        )
        #expect(
            Page.decide(isMainFrame: true, isLinkClick: true, url: URL(string: "about:blank#part"), expectsPage: false)
                == .allow
        )
    }

    // MARK: Encodings

    /// Only code pages the viewer can decode are offered: EUC-JP and GB 18030 are, ISO-2022, EUC-KR and HZ are not.
    @Test
    internal func codePagesThatCannotBeDecodedAreNotOffered() {
        // EUC-JP and GB 18030 were taken out in the first pass and are back (second pass), decoded by
        // their layout; other code pages of many bytes (ISO-2022, EUC-KR, HZ ...) are still not offered.
        #expect(ViewerEncoding.codePage(51_932) != nil && ViewerEncoding.codePage(54_936) != nil)
        for page in [50_220, 50_221, 50_222, 51_949, 52_936] {
            #expect(ViewerEncoding.codePage(page) == nil, "\(page)")
        }
        for page in [1_252, 437, 866, 932, 936, 949, 950, 28_591, 20_866, 65_001] {
            #expect(ViewerEncoding.codePage(page) != nil, "\(page)")
        }
        #expect(ViewerEncoding.codePages.contains(.ansi) && ViewerEncoding.codePages.contains { $0.codePage == 932 })
    }

    // MARK: Folders

    /// Counting a folder stops at its limit of entries and says the count is partial.
    @Test
    internal func countingAFolderOnAServerStopsAtItsLimit() {
        let memory = MemoryFileSystem()
        for folder in 0..<5 {
            for file in 0..<20 { memory.addFile("/tree/d\(folder)/f\(file).txt", String(repeating: "a", count: 10)) }
        }
        let all = FolderSummary.measure(
            memory.url("/tree"),
            provider: memory,
            cancellation: CancellationFlag(),
            limit: nil
        )
        #expect(all.files == 100 && all.folders == 5 && !all.isPartial)
        let limited = FolderSummary.measure(
            memory.url("/tree"),
            provider: memory,
            cancellation: CancellationFlag(),
            limit: 30
        )
        #expect(limited.isPartial && limited.files < 100 && limited.text.hasPrefix("At least "))
    }
}
