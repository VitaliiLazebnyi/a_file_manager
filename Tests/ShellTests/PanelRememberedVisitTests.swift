import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// A visit of a folder the listing cache remembers, by itself: shown at once and read afresh
/// behind, also when the fresh reading is one that was already under way (read ahead), comes
/// before the remembered listing is in the list, or fails.
@MainActor
@Suite(.serialized)
internal struct PanelRememberedVisitTests {
    /// A reading ahead the test has taken over, and what the panel did with it.
    @MainActor
    private final class Ahead {
        var receivers: [@MainActor (ReadAhead.Outcome) -> Void] = []
        var left = 0

        /// The reading as the panel joins it.
        var joined: ReadAhead.Joined {
            ReadAhead.Joined(
                receive: { [weak self] in self?.receivers.append($0) },
                leave: { [weak self] in self?.left += 1 }
            )
        }

        /// The reading ends with `outcome`.
        func end(_ outcome: ReadAhead.Outcome) {
            for receive in receivers {
                receive(outcome)
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    private let kernel: Kernel
    private let interaction = ScriptedInteraction()
    private let memory = MemoryFileSystem()
    private let host = PanelFakeHost()
    private let panel: PanelViewController

    /// A panel on a share (`/a` with `x.txt`, `/b` with `y.txt`), with the test's host.
    internal init() {
        kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: interaction)
        memory.isLocal = false
        memory.addFile("/a/x.txt")
        memory.addFile("/b/y.txt")
        kernel.fileSystems.register(memory)
        panel = PanelViewController(tabs: PanelTabs(PanelModel(directory: memory.url("/b"))), kernel: kernel)
        panel.host = host
        panel.view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
    }

    /// Shows `path` and waits until it is read.
    private func show(_ path: String) async {
        panel.show(memory.url(path), focus: nil, history: .record, completion: nil)
        await PanelWait.until { !panel.isLoading }
    }

    /// `/a` was visited (and is remembered); the panel is back in `/b`.
    private func rememberA() async {
        await show("/a")
        await show("/b")
    }

    /// What the cache remembers of `/a`, as a reading of it brings it, with `items` instead.
    private func freshA(_ items: [String]) throws -> PanelLoading.Whole {
        let entry = try #require(kernel.listingCache.entry(for: memory.url("/a"), showHidden: false))
        let listing = entry.listing.with(
            items: items.map { name in
                FileItem(url: memory.url("/a/" + name), name: name)
            }
        )
        return PanelLoading.Whole(listing: listing, focus: nil, order: entry.order)
    }

    /// A remembered folder that is being read ahead takes that reading over: the remembered list is
    /// shown at once and brought up to date when the reading comes.
    @Test
    internal func aRememberedFolderTakesOverAReadingAhead() async throws {
        await rememberA()
        let ahead = Ahead()
        host.joinable = ahead.joined
        memory.addFile("/a/new.txt")
        panel.show(memory.url("/a"), focus: nil, history: .record, completion: nil)
        #expect(panel.model.items.map(\.name) == ["x.txt"] && ahead.receivers.count == 1)
        ahead.end(.success(try freshA(["new.txt", "x.txt"])))
        #expect(await PanelWait.until { !panel.isLoading })
        #expect(panel.model.items.map(\.name) == ["new.txt", "x.txt"] && ahead.left == 0)
    }

    /// A reading ahead that fails takes the tab back and makes the folder forgotten.
    @Test
    internal func aReadingAheadThatFailsTakesTheTabBack() async {
        await rememberA()
        let ahead = Ahead()
        host.joinable = ahead.joined
        panel.show(memory.url("/a"), focus: nil, history: .record, completion: nil)
        ahead.end(.failure(CocoaError(.fileReadNoPermission)))
        #expect(await PanelWait.until { !panel.isLoading })
        #expect(panel.model.directory.path == "/b")
        #expect(kernel.listingCache.entry(for: memory.url("/a"), showHidden: false) == nil)
    }

    /// When the fresh listing comes before the remembered one is in the list (which waited to be
    /// put in the tab's order), the fresh one is shown and the remembered one never is.
    @Test
    internal func aFreshListingThatComesFirstIsShownInstead() async throws {
        await rememberA()
        panel.model.setSort(ListOrder(key: .name, descending: true))
        let ahead = Ahead()
        host.joinable = ahead.joined
        panel.show(memory.url("/a"), focus: nil, history: .record, completion: nil)
        ahead.end(.success(try freshA(["x.txt", "z.txt"])))
        #expect(await PanelWait.until { !panel.isLoading })
        #expect(panel.model.directory.path == "/a" && panel.model.items.map(\.name) == ["z.txt", "x.txt"])
    }

    /// A visit that is overtaken by another reading leaves the reading ahead it took over.
    @Test
    internal func anOvertakenVisitLeavesTheReadingAhead() async {
        await rememberA()
        let ahead = Ahead()
        host.joinable = ahead.joined
        panel.show(memory.url("/a"), focus: nil, history: .record, completion: nil)
        panel.show(memory.url("/b"), focus: nil, history: .record, completion: nil)
        #expect(await PanelWait.until { ahead.left == 1 && !panel.isLoading })
        ahead.end(.failure(CocoaError(.fileReadNoPermission)))
        await PanelWait.drainMainQueue()
        #expect(panel.model.directory.path == "/b")
    }

    /// A remembered folder entered while the tab is opening another (slow) one goes back, when
    /// its fresh reading fails before it was shown, to where the tab came from, not to the folder
    /// that was still opening.
    @Test
    internal func aVisitThatFailsWhileTheTabWasOpeningGoesBackToWhereItCameFrom() async {
        await rememberA()
        let slow = ScriptedFileSystem()
        slow.inner.addDirectory("/c")
        slow.batches = [[slow.item(named: "z.txt", in: "/c")]]
        slow.holdBefore = 0
        kernel.fileSystems.register(slow)
        defer { slow.open() }
        panel.show(slow.url("/c"), focus: nil, history: .record, completion: nil)
        #expect(await PanelWait.until { panel.model.isOpening })
        panel.model.setSort(ListOrder(key: .name, descending: true))
        let ahead = Ahead()
        host.joinable = ahead.joined
        panel.show(memory.url("/a"), focus: nil, history: .record, completion: nil)
        ahead.end(.failure(CocoaError(.fileReadNoPermission)))
        #expect(await PanelWait.until { !panel.isLoading })
        #expect(panel.model.directory.path == "/b")
        #expect(await PanelWait.until { !interaction.log.isEmpty })
    }

    /// A visit overtaken before its fresh reading had its turn does not ask the file system.
    @Test
    internal func aVisitOvertakenBeforeItsTurnAsksNothing() async {
        await rememberA()
        let gate = DispatchSemaphore(value: 0)
        Background.storage("list", at: memory.url("/a")) { gate.wait() }
        panel.show(memory.url("/a"), focus: nil, history: .record, completion: nil)
        panel.show(memory.url("/b"), focus: nil, history: .record, completion: nil)
        gate.signal()
        // The lane runs one call at a time: once a marker queued behind the reading has run, it is done.
        let laneDone = Shared(false)
        Background.storage("list", at: memory.url("/a")) { laneDone.value = true }
        #expect(await PanelWait.until { !panel.isLoading && laneDone.value })
        #expect(panel.model.directory.path == "/b" && memory.listRequests(for: "/a") == 1)
    }
}
