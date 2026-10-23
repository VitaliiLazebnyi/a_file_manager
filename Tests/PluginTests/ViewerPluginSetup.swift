import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import TestSupport

@testable import ViewerPlugin

/// The viewer over a memory file system with a few files of every kind, its Lister windows never put on screen,
/// and the quick view over fake panels: what the viewer's window tests start from.
@MainActor
internal struct ViewerPluginSetup {
    /// Stands in for the part of a panel the quick view covers.
    internal final class OverlayHost: PanelOverlayHost {
        /// The view shown in place of the panel's file list, or nil.
        internal var overlay: NSView?

        deinit {
            // Nothing to release.
        }
    }

    /// The covers of the panels, filled in once the panels exist, for the viewer to look them up in.
    private final class HostLookup {
        /// The cover of each panel, by the panel's identity.
        var hosts: [ObjectIdentifier: OverlayHost] = [:]

        deinit {
            // Nothing to release.
        }
    }

    /// The file system the files are read from.
    internal let memory = MemoryFileSystem()
    /// The program around the viewer, its two panels on the memory file system.
    internal let bench: TestBench
    /// The viewer, with a short quick view delay and no windows put on the screen.
    internal let plugin: ViewerPlugin
    /// The cover of each of the two panels, by the panel's identity.
    internal let hosts: [ObjectIdentifier: OverlayHost]
    /// A pasteboard of the tests' own, so that copying does not touch the user's.
    internal let scratch = ScratchPasteboard()

    /// Writes the files (texts, HTML, a binary, UTF-16 with a mark, a broken image), then makes the viewer and the
    /// program with a cover for each panel.
    internal init() throws {
        _ = NSApplication.shared
        var lines: [String] = []
        for number in 1...5_000 {
            lines.append("Line \(number) of the long text, needle\(number.isMultiple(of: 1_000) ? " GOLD" : "")")
        }
        memory.addFile("/A/long.txt", lines.joined(separator: "\n"))
        memory.addFile("/A/short.txt", "Grüße\tfrom a file\nsecond line")
        memory.addFile(
            "/A/page.html",
            "<html><body><h1>Title</h1><p>See <a href=\"https://example.com\">this</a>.</p></body></html>"
        )
        memory.addFile("/A/docs/inner.txt", "inside")
        memory.addFile("/A/docs/more/deep.txt", "12345")
        memory.addFile("/B/other.txt", "other")
        try Self.write(
            Data([0x4D, 0x5A, 0x00, 0x01, 0x02, 0x03] + Array(repeating: UInt8(0xFF), count: 300)),
            to: "/A/tool.bin",
            in: memory
        )
        try Self.write(
            Data([0xFF, 0xFE] + ViewerEncoding.utf16LE.encode("Wide text\r\nzwei")),
            to: "/A/wide.txt",
            in: memory
        )
        try Self.write(
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]),
            to: "/A/broken.png",
            in: memory
        )
        var covers: [ObjectIdentifier: OverlayHost] = [:]
        let lookup = HostLookup()
        plugin = ViewerPlugin(
            overlayHost: { lookup.hosts[ObjectIdentifier($0)] },
            quickViewDelay: 0.01,
            showsWindows: false
        )
        bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/B"))
        covers[ObjectIdentifier(bench.left)] = OverlayHost()
        covers[ObjectIdentifier(bench.right)] = OverlayHost()
        lookup.hosts = covers
        hosts = covers
    }

    /// Writes the bytes as the file at `path` of the memory file system.
    private static func write(_ data: Data, to path: String, in memory: MemoryFileSystem) throws {
        let writer = try memory.write(memory.url(path))
        try writer.write(data)
        try writer.close(attributes: FileAttributes())
    }
}
