import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// Carrying out on whole trees (spec 09 › The "Synchronize" dialog and the run): mirrors, folders,
/// deletions, other targets and other file systems.
@Suite
internal struct SyncExecutingTrees {
    /// The trees and their file systems.
    private let fixture = SyncRunFixture()

    /// The trees.
    private var memory: MemoryFileSystem { fixture.memory }
    /// The local and the memory file system.
    private var fileSystems: FileSystemRegistry { fixture.fileSystems }
    /// The date the files are dated from.
    private var early: Date { SyncRunFixture.early }

    /// A mirror makes the right a copy of the left, deleting empty folders on request.
    @Test
    internal func asymmetricMakesTheRightACopyOfTheLeft() {
        memory.addFile("/R/stale/old.txt", "stale")
        memory.addDirectory("/R/hollow/inner")
        memory.addDirectory("/L/hollow")
        var all = fixture.rows { options in
            options.asymmetric = true
            options.emptyDirectories = true
        }
        // The user also sends the left version of the file that is newer on the right.
        for index in all.indices where all[index].name == "back.txt" { all[index].action = .copyToRight }
        let plan = SyncPlan(rows: all)
        #expect(plan.toLeft.isEmpty && plan.deleteRight.count == 6)
        let outcome = fixture.runWithOptions(plan) { options in options.removeEmptyDirectoriesBelow = memory.url("/R") }
        #expect(outcome.errors.isEmpty && outcome.skipped == 0)
        // "Delete all empty directories" also takes those the left has (spec 09 › dialog).
        #expect(
            memory.allPaths.filter { $0.hasPrefix("/R") } == [
                "/R", "/R/back.txt", "/R/new.txt", "/R/same.txt", "/R/update.txt"
            ]
        )
        #expect(memory.contents("/R/back.txt") == "older")
    }

    /// Folders are created, and a folder the user kept a file in stays.
    @Test
    internal func foldersAreCreatedAndAFolderTheUserKeptAFileInStays() {
        memory.addDirectory("/L/fresh/inner")
        memory.addFile("/R/doomed/keep.txt")
        memory.addFile("/R/doomed/go.txt")
        var all = fixture.rows { options in
            options.asymmetric = true
            options.emptyDirectories = true
        }
        for index in all.indices where all[index].name == "keep.txt" { all[index].action = .nothing }
        let outcome = fixture.run(
            SyncPlan(
                rows: all.filter { row in
                    row.directory.hasPrefix("doomed") || row.name == "doomed" || row.relativePath.hasPrefix("fresh")
                }
            )
        )
        #expect(
            memory.exists("/R/fresh/inner") && memory.exists("/R/doomed/keep.txt") && !memory.exists("/R/doomed/go.txt")
        )
        #expect(outcome.errors.isEmpty && outcome.skipped == 1 && outcome.deleted == 1 && outcome.copied == 2)
    }

    /// Deletions on both sides and on the left; parts switched off do not run.
    @Test
    internal func deletingOnBothSidesAndOnTheLeft() {
        var all = fixture.rows()
        for index in all.indices {
            if all[index].name == "same.txt" { all[index].action = .deleteBoth }
            if all[index].name == "new.txt" { all[index].action = .deleteLeft }
            if all[index].name == "update.txt" { all[index].action = .nothing }
        }
        var outcome = fixture.runWithOptions(SyncPlan(rows: all)) { options in
            options.deleteLeft = false
            options.copyToLeft = false
        }
        // Parts of the plan the dialog switched off are not run.
        #expect(
            outcome.deleted == 1 && outcome.copied == 0 && memory.exists("/L/same.txt") && !memory.exists("/R/same.txt")
                && !memory.exists("/L/sub")
        )
        outcome = fixture.run(SyncPlan(rows: all.filter { $0.name != "same.txt" }))
        #expect(!memory.exists("/L/new.txt") && memory.exists("/L/sub/deep/arrives.txt") && outcome.deleted == 1)
    }

    /// Copies sent to another folder keep their relative paths.
    @Test
    internal func anotherTargetFolderKeepsTheRelativePaths() {
        var plan = SyncPlan(rows: fixture.rows())
        plan.retarget(toRight: false, root: memory.url("/Elsewhere"))
        plan.retarget(toRight: true, root: memory.url("/Backup/today"))
        fixture.run(plan)
        #expect(
            memory.contents("/Elsewhere/sub/deep/arrives.txt") == "from the right"
                && memory.contents("/Backup/today/new.txt") == "from the left"
        )
        #expect(memory.contents("/L/back.txt") == "older" && !memory.exists("/L/sub"))
    }

    /// Synchronizing works between the disk and another file system.
    @Test
    internal func worksBetweenDiskAndAnotherFileSystem() throws {
        let box = try Sandbox()
        try box.file("L/disk.txt", "from the disk", modified: early.addingTimeInterval(100))
        try box.file("L/both.txt", "disk version, newer", modified: early.addingTimeInterval(100))
        try box.file("L/nested/deep.txt", "deep", modified: early)
        memory.addFile("/M/both.txt", "memory version", modified: early)
        memory.addFile("/M/mem/only.txt", "from memory", modified: early.addingTimeInterval(50))
        func compare() -> [SyncRow] {
            var options = SyncOptions()
            options.byContent = true
            return SyncComparison(options: options, fileSystems: fileSystems)
                .run(
                    left: box.url("L"),
                    right: memory.url("/M")
                )
                .rows
        }
        let outcome = fixture.run(SyncPlan(rows: compare()))
        #expect(outcome.errors.isEmpty && outcome.copied == 4)
        #expect(
            memory.contents("/M/disk.txt") == "from the disk" && memory.contents("/M/both.txt") == "disk version, newer"
        )
        #expect(memory.contents("/M/nested/deep.txt") == "deep" && box.read("L/mem/only.txt") == "from memory")
        #expect(namesOnDisk(box.url("L")) == ["both.txt", "disk.txt", "mem", "nested"])
        let after = compare()
        #expect(after.count == 4 && after.allSatisfy { $0.state == .equal })
    }

    /// A file system that copies nothing itself is streamed to, dates included.
    @Test
    internal func aFileSystemThatCopiesNothingItselfIsStreamed() {
        memory.refusesInternalCopy = true
        let outcome = fixture.run(SyncPlan(rows: fixture.rows()))
        #expect(
            outcome.copied == 4 && outcome.errors.isEmpty && memory.contents("/R/update.txt") == "newer on the left"
        )
        #expect(memory.item(at: memory.url("/R/update.txt"))?.modified == early.addingTimeInterval(60))
    }
}
