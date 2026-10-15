import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Names and paths from outside: archives, servers, the fuzzers' findings (review 2, K037).
@Suite
internal struct PathSafetyTests {
    /// The folder the paths are checked against.
    private static let root = URL(fileURLWithPath: "/tmp/review2-root")

    /// The URL written as `text`.
    private static func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    /// A name of one part is taken, accents and odd dots included; empty names, dots, separators
    /// (also with an accent on them) and NUL are refused.
    @Test
    internal func aNameIsOneNameOrItIsRefused() {
        for name in ["a", "a.txt", "..a", "a..", "...", " ", "é", "a\u{301}", "\u{301}", "a\\b", "a b"] {
            #expect(PathSafety.isSafeName(name), "\(name.debugDescription)")
        }
        // The separator is a byte: one that carries an accent is still a separator.
        for name in [
            "", ".", "..", "a/b", "/", "/a", "a/", "a\u{0}b", "\u{0}", "/\u{301}", "a/\u{301}b", "../x",
            "..\u{2F}\u{301}"
        ] {
            #expect(!PathSafety.isSafeName(name), "\(name.debugDescription)")
        }
        #expect(Self.root.appending(safeName: "x.txt")?.path == "/tmp/review2-root/x.txt")
        #expect(Self.root.appending(safeName: "../x") == nil)
        #expect(Self.root.appending(safeName: "a/b") == nil)
        #expect(Self.root.appending(safeName: "..") == nil)
    }

    /// A relative path is cut at the separator byte and every part checked; whatever climbs,
    /// starts at the root or holds an empty part is refused.
    @Test
    internal func aPathIsCutAtTheByteAndEveryPartChecked() {
        #expect(PathSafety.components(ofRelativePath: "a/b/c.txt") == ["a", "b", "c.txt"])
        #expect(PathSafety.components(ofRelativePath: "dir/", allowingTrailingSeparator: true) == ["dir"])
        #expect(PathSafety.components(ofRelativePath: "a/\u{301}b") == ["a", "\u{301}b"])
        // What the archive and split-file reproducers held: `..`, then a `/` with a combining
        // mark, which one character-based split took for part of a name.
        for path in [
            "../x", "a/../b", "..", ".", "a/./b", "/abs", "a//b", "a/", "", "a/\u{0}", "..\u{2F}\u{301}x",
            "..\u{2F}\u{301}/..\u{2F}\u{301}/x", "a/..\u{2F}\u{301}"
        ] {
            #expect(PathSafety.components(ofRelativePath: path).isEmpty, "\(path.debugDescription)")
        }
        #expect(PathSafety.components(ofRelativePath: "a/b//", allowingTrailingSeparator: true).isEmpty)
    }

    /// Below the root means below it by the bytes of the path, on the same server.
    @Test
    internal func aLocationIsBelowItsRootByBytesNotByLooks() throws {
        let base = Self.root
        #expect(PathSafety.isContained(URL(fileURLWithPath: "/tmp/review2-root/a/b"), in: base))
        #expect(PathSafety.isContained(URL(fileURLWithPath: "/tmp/review2-root/a/../b"), in: base))
        #expect(!PathSafety.isContained(base, in: base))
        #expect(!PathSafety.isContained(URL(fileURLWithPath: "/tmp/review2-root/../x"), in: base))
        #expect(!PathSafety.isContained(URL(fileURLWithPath: "/tmp/review2-rootx/a"), in: base))
        #expect(!PathSafety.isContained(URL(fileURLWithPath: "/tmp/review2-root\u{301}/a"), in: base))
        #expect(!PathSafety.isContained(try Self.url("ftp://host/tmp/review2-root/a"), in: base))
        #expect(PathSafety.isContained(try Self.url("ftp://host/pub/a"), in: try Self.url("ftp://host/pub")))
        #expect(!PathSafety.isContained(try Self.url("ftp://other/pub/a"), in: try Self.url("ftp://host/pub")))
        #expect(!URL(fileURLWithPath: "/tmp/review2-root\u{301}/a").isInside(base))
    }

    /// Two folders whose names read the same are two folders, where the file system keeps both
    /// (a server; the Mac's own disks write every name one way).
    @Test
    internal func foldersWhoseNamesReadTheSameAreTwoFolders() throws {
        let composed = try Self.url("ftp://host/caf%C3%A9")
        let decomposed = try Self.url("ftp://host/cafe%CC%81/x")
        #expect(composed.path == decomposed.deletingLastPathComponent().path)
        #expect(!PathSafety.isContained(decomposed, in: composed) && !decomposed.isInside(composed))
        let inside = try Self.url("ftp://host/caf%C3%A9/x")
        #expect(inside.isInside(composed) && PathSafety.isContained(inside, in: composed))
    }

    /// A link inside the folder that points out of it is inside by its path, and outside once
    /// links are resolved.
    @Test
    internal func aLinkOutOfTheFolderIsOutsideWhenLinksAreResolved() throws {
        let sandbox = try Sandbox()
        let inside = try sandbox.folder("inside")
        let outside = try sandbox.folder("outside")
        try FileManager.default.createSymbolicLink(
            at: inside.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        let through = inside.appendingPathComponent("link/file.txt")
        #expect(PathSafety.isContained(through, in: inside))
        #expect(!PathSafety.isContained(through, in: inside, resolvingLinks: true))
        #expect(PathSafety.isContained(inside.appendingPathComponent("plain.txt"), in: inside, resolvingLinks: true))
    }
}
