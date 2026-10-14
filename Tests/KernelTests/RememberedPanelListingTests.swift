import AFMKernel
import Foundation
import TestSupport
import Testing

/// The panel model's side of "show old, refresh behind": a remembered listing shown until the
/// fresh one arrives.
@MainActor
@Suite
internal struct RememberedPanelListingTests {
    private let work: WorkPanel

    /// A panel showing `/work`.
    internal init() throws {
        work = try WorkPanel()
    }

    /// A remembered listing can be used but is not known to be complete; the fresh listing
    /// takes its place and keeps cursor, marks and history.
    @Test
    internal func aRememberedListingIsShownUntilTheFreshOneArrives() throws {
        let panel = work.panel
        work.memory.addFile("/work/docs/new.txt")
        work.memory.addFile("/work/docs/old.txt")
        panel.showRemembered(try work.listing("/work/docs"), focus: "old.txt")
        // It can be used, but it is not known to be all there is.
        #expect(panel.directory.path == "/work/docs")
        #expect(panel.isListed)
        #expect(panel.isRefreshing)
        #expect(!panel.isComplete)
        #expect(!panel.isOpening)
        #expect(panel.cursorItem?.name == "old.txt")
        #expect(panel.backLocation?.path == "/work")
        panel.toggleSelection(row: panel.cursor)
        // The fresh listing takes its place and keeps cursor and selection.
        work.memory.addFile("/work/docs/another.txt")
        #expect(panel.update(with: try work.listing("/work/docs")))
        #expect(panel.isComplete)
        #expect(!panel.isRefreshing)
        #expect(panel.items.count == 3)
        #expect(panel.cursorItem?.name == "old.txt")
        #expect(panel.selection == ["old.txt"])
        #expect(panel.backLocation?.path == "/work")
    }

    /// When the fresh reading fails, restoring the snapshot takes the panel back to where it was;
    /// a snapshot taken in between remembers that the list was only a remembered one.
    @Test
    internal func aFailedRefreshGoesBackAndASnapshotRemembersTheWaiting() throws {
        let panel = work.panel
        let remembered = try work.listing("/work/docs")
        let before = panel.snapshot()
        panel.showRemembered(remembered)
        #expect(panel.isRefreshing)
        #expect(panel.items.isEmpty)
        panel.restore(before)
        #expect(panel.directory.path == "/work")
        #expect(panel.isComplete)
        #expect(!panel.isRefreshing)
        #expect(panel.forwardLocation == nil)
        // A snapshot taken in between remembers that the list was only a remembered one.
        panel.showRemembered(remembered)
        let between = panel.snapshot()
        try work.show("/work/bin")
        panel.restore(between)
        #expect(panel.directory.path == "/work/docs")
        #expect(panel.isRefreshing)
        #expect(!panel.isComplete)
        panel.finishLoading()
        #expect(panel.isComplete)
        #expect(!panel.isRefreshing)
    }
}
