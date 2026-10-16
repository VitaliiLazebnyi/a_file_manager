import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// A panel by itself on a share in memory (`/a` with `x.txt`, `/b` with `y.txt`), with a host
/// the test answers for and a file system whose listings the test holds (`script`), for the tests
/// of what happens when an answer from the background meets a panel that has moved on.
@MainActor
internal final class ShellFixPanel {
    /// A reading ahead the test has handed the panel, and what the panel did with it.
    @MainActor
    internal final class Ahead {
        /// Who waits for the reading's result.
        internal private(set) var receivers: [@MainActor (ReadAhead.Outcome) -> Void] = []
        /// How often the panel left the reading.
        internal private(set) var left = 0

        /// The reading as the panel joins it.
        internal var joined: ReadAhead.Joined {
            ReadAhead.Joined(
                receive: { [weak self] in self?.receivers.append($0) },
                leave: { [weak self] in self?.left += 1 }
            )
        }

        /// The reading ends with `outcome`.
        internal func end(_ outcome: ReadAhead.Outcome) {
            for receive in receivers {
                receive(outcome)
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The kernel.
    internal let kernel: Kernel
    /// The user, as the test scripts them.
    internal let interaction = ScriptedInteraction()
    /// The share.
    internal let memory = MemoryFileSystem()
    /// A file system whose listings hold where the test says (`script://`).
    internal let script = ScriptedFileSystem()
    /// The panel's surroundings.
    internal let host = PanelFakeHost()
    /// The panel, which starts in `/b`.
    internal let panel: PanelViewController

    /// The panel's active tab.
    internal var model: PanelModel { panel.model }
    /// The names the panel shows.
    internal var names: [String] { panel.model.items.map(\.name) }

    /// The panel, its folders and its file systems.
    internal init() {
        kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: interaction)
        memory.isLocal = false
        memory.addFile("/a/x.txt")
        memory.addFile("/b/y.txt")
        kernel.fileSystems.register(memory)
        kernel.fileSystems.register(script)
        // No job runs: the panel may read again whenever it wants to.
        kernel.commands.isBlocked = { false }
        panel = PanelViewController(tabs: PanelTabs(PanelModel(directory: memory.url("/b"))), kernel: kernel)
        panel.host = host
        panel.view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
    }

    /// Names of `count` entries.
    internal static func names(_ count: Int) -> [String] {
        (0..<count).map { String(format: "f%06d.txt", $0) }
    }

    /// Shows `location` and waits until it is read.
    internal func show(_ location: URL) async {
        panel.show(location, focus: nil, history: .record, completion: nil)
        await PanelWait.until { !panel.isLoading }
    }

    /// Shows `path` of the share and waits until it is read.
    internal func show(_ path: String) async {
        await show(memory.url(path))
    }

    /// `path` was visited (and is remembered); the panel is back in `/b`.
    internal func remember(_ path: String) async {
        await show(path)
        await show("/b")
    }

    /// What the cache remembers of `path`, as a reading of it brings it, with entries called `items`
    /// instead, in the order of their names.
    internal func fresh(_ path: String, _ items: [String]) throws -> PanelLoading.Whole {
        let entry = try #require(kernel.listingCache.entry(for: memory.url(path), showHidden: false))
        let listing = entry.listing.with(
            items: items.sorted()
                .map { name in
                    FileItem(url: memory.url(path + "/" + name), name: name)
                }
        )
        return PanelLoading.Whole(listing: listing, focus: nil, order: ListOrder(key: .name, descending: false))
    }

    /// A reading ahead that the panel takes over on its next visit.
    internal func readingAhead() -> Ahead {
        let ahead = Ahead()
        host.joinable = ahead.joined
        return ahead
    }

    /// `/c` of `script` with `z1.txt` to `z3.txt`, of which the listing delivers the first two (as
    /// the first piece) and then holds until the test opens it.
    internal func holdHalfOfC() {
        script.inner.addDirectory("/c")
        script.batches = ["z1.txt", "z2.txt", "z3.txt"].map { [script.item(named: $0, in: "/c")] }
        script.holdBefore = 2
        // The second batch comes after the first piece's time, so that the two leave as the first piece.
        script.pauseBeforeSecondBatch = PanelLoading.firstPieceDelay * 2
    }

    /// The panel enters `/c` (`holdHalfOfC`) and waits until it shows the first half of it.
    internal func enterHalfOfC() async {
        holdHalfOfC()
        panel.show(script.url("/c"), focus: nil, history: .record, completion: nil)
        await PanelWait.until { model.directory.path == "/c" && model.isListed && model.items.count == 2 }
    }

    deinit {
        // Nothing to release.
    }
}
