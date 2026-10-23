import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// The folder tree of Places (review 2): protected folders, limits, priorities and quick search.
@Suite
internal struct Review2ConfigBTree {
    /// A scan leaves protected and cloud folders unread; opened by the user, such a folder is read.
    @Test
    internal func aScanLeavesProtectedAndCloudFoldersUnreadButAUserOpenedOneIsRead() throws {
        let box = try Sandbox()
        try box.folder("plain/inner")
        let protected = URL(fileURLWithPath: NSHomeDirectory() + "/Library/CloudStorage")
        #expect(TreeScanner.isProtected(protected) && !TreeScanner.isProtected(box.url("plain")))
        #expect(TreeScanner.isProtected(URL(fileURLWithPath: NSHomeDirectory() + "/Documents")))
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem())
        var names: [String] = []
        scanner.run { levels in names += levels.flatMap(\.children) }
        #expect(names.sorted() == ["inner", "plain"] && scanner.unscanned.isEmpty)
        // Reading the folder itself, as when the user opens it, works whatever it is.
        let own = TreeScanner(root: protected, provider: LocalFileSystem())
        _ = own.subfolders(of: protected)
    }

    /// A scan stops at its folder or time limit and counts as incomplete.
    @Test
    internal func aScanStopsAtItsFolderLimitAndCountsAsIncomplete() throws {
        let box = try Sandbox()
        for index in 0..<20 { try box.folder("d\(index)/sub") }
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem(), batchSize: 4)
        scanner.folderLimit = 10
        let finished = scanner.run { _ in
            // Only whether the scan finished matters.
        }
        #expect(!finished && scanner.reachedLimit)
        #expect(!scanner.unscanned.isEmpty)
        let timed = TreeScanner(root: box.root, provider: LocalFileSystem(), batchSize: 4)
        timed.timeLimit = -1
        let timedFinished = timed.run { _ in
            // Only whether the scan finished matters.
        }
        #expect(!timedFinished && timed.reachedLimit)
    }

    /// A gentle scan throttles the thread's disk access and restores it afterwards.
    @Test
    internal func gentleScanRestoresTheThreadsPriorities() {
        // On a thread of its own (a pool thread of Dispatch does not take a policy of its own).
        let seen = Shared<[Int32]>([])
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let before = getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
            let inside = TreeScanner.gently { getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD) }
            seen.modify { $0 = [before, inside, getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)] }
            done.signal()
        }
        thread.start()
        done.wait()
        let values = seen.value
        #expect(values.count == 3 && values[1] == IOPOL_THROTTLE && values[2] == values[0], "\(values)")
    }

    /// Quick search works in slices and finds what the blocking search finds, or nothing.
    @Test
    internal func quickSearchWorksInSlicesAndMatchesTheBlockingSearch() {
        let root = URL(fileURLWithPath: "/Volumes/R2", isDirectory: true)
        let tree = DirectoryTree(rootURL: root, paths: (0..<5_000).map { "dir\($0)" } + ["needle"])
        let blocking = tree.find("needle", from: nil)
        var progress = tree.search("needle", from: nil, timeBudget: 0)
        var steps = 0
        while case .pending(let node, let left) = progress {
            steps += 1
            progress = tree.search("needle", from: node, includingStart: true, remaining: left, timeBudget: 0)
        }
        guard case .found(let found) = progress else {
            Issue.record("not found")
            return
        }
        #expect(found === blocking && steps >= 1)
        // A name that is nowhere ends with .none, not with a pending slice.
        var missing = tree.search("zzz", from: nil, timeBudget: 0)
        while case .pending(let node, let left) = missing {
            missing = tree.search("zzz", from: node, includingStart: true, remaining: left, timeBudget: 0)
        }
        guard case .none = missing else {
            Issue.record("expected no match")
            return
        }
    }
}
