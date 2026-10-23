import AFMKernel
import TestSupport
import Testing

@testable import NavigationPlugin
@testable import VirtualFoldersPlugin

/// Round 2 of the review, second pass, Navigation and Virtual Folders: a path from a very long clipboard line, and
/// lists of files known to hold no name twice.
@Suite
internal struct Review2PluginsA2Lists {
    /// A path is taken from the start of a very long clipboard line, cut to a bounded length; quotes and blank
    /// lines around it are dropped.
    @Test
    internal func aPathIsTakenFromTheStartOfAVeryLongClipboardLine() {
        let long = "/Users/me/Documents" + String(repeating: "x", count: 5_000_000)
        let path = NavigationPlugin.path(fromClipboard: long)
        #expect(path?.hasPrefix("/Users/me/Documents") == true && (path?.utf8.count ?? .max) <= 8_192)
        #expect(NavigationPlugin.path(fromClipboard: "\n\n  \"/a b\"  \nsecond") == "/a b")
    }

    /// A list registered as unique keeps every file as given; another list loses its doubles.
    @Test
    internal func aListThatIsKnownToBeUniqueIsNotLookedThroughForDoubles() {
        let fileSystems = FileSystemRegistry()
        let memory = MemoryFileSystem()
        fileSystems.register(memory)
        let virtual = VirtualFileSystem(fileSystems: fileSystems)
        let files = [memory.url("/a"), memory.url("/b"), memory.url("/a")]
        let plain = virtual.register(files: files, title: "t", origin: nil)
        let unique = virtual.register(files: files, title: "t", origin: nil, isUnique: true)
        #expect(virtual.entries(of: plain).count == 2)
        #expect(virtual.entries(of: unique).count == 3)
    }
}
