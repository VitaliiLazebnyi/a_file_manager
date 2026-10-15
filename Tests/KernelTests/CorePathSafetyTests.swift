import AFMKernel
import Foundation
import TestSupport
import Testing

/// Whether a path from outside stays below the folder it was meant for.
@Suite
internal struct CorePathSafetyTests {
    private let root = URL(fileURLWithPath: "/tmp/core-root")

    /// A location below the root, written as `text` after it.
    private func path(_ text: String) -> URL { URL(fileURLWithPath: "/tmp/core-root" + text) }

    /// An empty name is no name: `root//../a` lies beside the root, as the file system reads it.
    @Test
    internal func anEmptyNameIsNoNameForTheWayUp() {
        // The file system reads `//` as `/`: `root//../a` is beside the root, not in it.
        #expect(!PathSafety.isContained(path("//../a"), in: root))
        #expect(!PathSafety.isContained(path("/a//.."), in: root))
        #expect(!PathSafety.isContained(path("/a//../../b"), in: root))
        #expect(PathSafety.isContained(path("/a//b"), in: root))
        #expect(PathSafety.isContained(path("/a/./b/../c"), in: root))
        #expect(!PathSafety.isContained(path("/a/../../core-root/b/../.."), in: root))
    }

    /// A `..` that leads above the start of the path lies nowhere, and the root `/` holds everything else.
    @Test
    internal func aWayUpAboveTheStartLiesNowhere() {
        #expect(!PathSafety.isContained(URL(fileURLWithPath: "/../tmp/core-root/a"), in: root))
        #expect(!PathSafety.isContained(path("/a"), in: URL(fileURLWithPath: "/..")))
        #expect(PathSafety.isContained(URL(fileURLWithPath: "/a"), in: URL(fileURLWithPath: "/")))
        #expect(!PathSafety.isContained(URL(fileURLWithPath: "/"), in: URL(fileURLWithPath: "/")))
    }

    /// The root itself, and a folder whose name only begins like it, are not below it.
    @Test
    internal func theRootItselfAndItsNeighboursAreNotBelowIt() {
        #expect(!PathSafety.isContained(root, in: root))
        #expect(!PathSafety.isContained(path("/"), in: root))
        #expect(!PathSafety.isContained(URL(fileURLWithPath: "/tmp/core-rootx/a"), in: root))
        #expect(PathSafety.isContained(path("/a"), in: path("/")))
    }

    /// A place of another scheme, host or port is never below the root.
    @Test
    internal func otherPlacesAreNeverBelowALocalFolder() {
        let server = URL(string: "ftp://host/tmp/core-root")!
        #expect(!PathSafety.isContained(URL(string: "ftp://host/tmp/core-root/a")!, in: root))
        #expect(!PathSafety.isContained(URL(string: "ftp://other/tmp/core-root/a")!, in: server))
        #expect(!PathSafety.isContained(URL(string: "ftp://host:21/tmp/core-root/a")!, in: server))
        #expect(PathSafety.isContained(URL(string: "ftp://host/tmp/core-root/a")!, in: server))
        #expect(!PathSafety.isContained(URL(string: "ftp://host/tmp/core-root//../a")!, in: server))
    }

    /// With links resolved, a link that leads out is out, and what does not exist yet stays where it is written.
    @Test
    internal func linksAreFollowedOnTheDiskWhenAsked() throws {
        let box = try Sandbox()
        let inside = box.url("inside")
        try box.folder("inside/real")
        try box.folder("outside/deep")
        try FileManager.default.createSymbolicLink(
            at: box.url("inside/out"),
            withDestinationURL: box.url("outside/deep")
        )
        // A link that leads out is out, with or without `..` after it, existing or not.
        #expect(PathSafety.isContained(box.url("inside/out/file"), in: inside))
        #expect(!PathSafety.isContained(box.url("inside/out/file"), in: inside, resolvingLinks: true))
        #expect(!PathSafety.isContained(box.url("inside/out/../x"), in: inside, resolvingLinks: true))
        #expect(!PathSafety.isContained(box.url("inside/real//../../x"), in: inside, resolvingLinks: true))
        // What is really inside stays inside, also where it does not exist yet.
        #expect(PathSafety.isContained(box.url("inside/real/new/file"), in: inside, resolvingLinks: true))
        #expect(PathSafety.isContained(box.url("inside/new//x"), in: inside, resolvingLinks: true))
        #expect(!PathSafety.isContained(box.url("inside/new/../../x"), in: inside, resolvingLinks: true))
        // Nothing of the path exists but the root.
        let nowhere = URL(fileURLWithPath: "/core-nowhere-\(UUID().uuidString)")
        #expect(PathSafety.isContained(nowhere.appending(name: "a"), in: nowhere, resolvingLinks: true))
    }
}
