import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// Folders of a partly read tree that are read when they are opened.
extension CoveragePlacesTreeWindow {
    /// A window on a stored tree whose folder B was not read.
    internal func partial() async -> CoveragePlacesTreeParts {
        let cache = TreeCache(directory: nil)
        cache.store(["A", "A/a1", "B"], for: root, unscanned: ["B"], isComplete: false)
        return await opened("/A", cache: cache, showHidden: false)
    }

    /// Opens the row titled `title` and everything inside it, as a click on its triangle does.
    internal func expand(_ title: String, in tree: CoveragePlacesTreeParts) {
        guard let outline = tree.outline, let item = outline.item(atRow: tree.row(titled: title)) else {
            Issue.record("no row titled \(title)")
            return
        }
        outline.collapseItem(item)
        outline.expandItem(item, expandChildren: true)
    }

    /// A folder opened before it was read is read then, once however often it is opened, and
    /// not again once it is read.
    @Test
    internal func aFolderOpenedBeforeItWasReadIsReadThenAndOnce() async {
        let tree = await partial()
        defer { tree.controller.close() }
        #expect(tree.rows == ["tree:/", "A", "B"])
        folders.hold("/B")
        expand("B", in: tree)
        expand("B", in: tree)
        #expect(await spin { folders.isWaiting("/B") })
        folders.release("/B")
        #expect(await spin { tree.rows.contains("b1") })
        #expect(tree.rows == ["tree:/", "A", "B", "b1"] && tree.status.hasPrefix("4 directories, incomplete"))
        // Read now: opening it again reads nothing.
        expand("B", in: tree)
        expand("A", in: tree)
        tree.controller.close()
    }

    /// The folder read for a tree the window no longer shows is dropped.
    @Test
    internal func aFolderReadForAnotherTreeIsDropped() async {
        let tree = await partial()
        defer { tree.controller.close() }
        folders.hold("/B")
        expand("B", in: tree)
        #expect(await spin { folders.isWaiting("/B") })
        tree.chooseRoot(3)
        #expect(await spin { tree.isIdle && tree.rows.first == "mem:/" })
        folders.release("/B")
        await CoveragePlacesLoop.settle()
        #expect(tree.rows == ["mem:/", "M"])
        tree.controller.close()
    }

    /// A folder that a rescan read before its own reading came back is not added a second time.
    @Test
    internal func aFolderTheRescanReadFirstIsNotReadAgain() async {
        let tree = await partial()
        defer { tree.controller.close() }
        folders.hold("/B")
        expand("B", in: tree)
        #expect(await spin { folders.isWaiting("/B") })
        tree.click("F2 Rescan Tree")
        #expect(await spin { tree.status == "9 directories" })
        folders.release("/B")
        await CoveragePlacesLoop.settle()
        #expect(tree.rows.filter { $0 == "b1" }.count == 1)
        tree.controller.close()
    }

    /// A folder whose reading comes back after the window closed finds no tree to go into.
    @Test
    internal func aFolderReadWhileTheWindowIsAwayFindsNoTree() async {
        let tree = await partial()
        defer { tree.controller.close() }
        folders.hold("/B")
        expand("B", in: tree)
        #expect(await spin { folders.isWaiting("/B") })
        // The stored tree is let go with the window; the folder's answer finds no tree.
        tree.controller.close()
        #expect(tree.rows.isEmpty)
        folders.release("/B")
        #expect(await spin { tree.status.isEmpty })
    }

    /// A folder opened while the scan still runs is read on its own, ahead of the scan.
    @Test
    internal func aFolderOpenedWhileTheScanRunsIsReadOnItsOwn() async {
        folders.hold("/A")
        let tree = window(cache: TreeCache(directory: nil))
        defer { tree.controller.close() }
        tree.controller.show(for: folders.url("/Home"), showHidden: false)
        #expect(await spin { folders.isWaiting("/A") && tree.rows.contains("B") })
        expand("B", in: tree)
        #expect(await spin { tree.rows.contains("b1") })
        #expect(tree.status.hasPrefix("Reading directories"))
        folders.release("/A")
        #expect(await spin { tree.isIdle })
        tree.controller.close()
    }
}
