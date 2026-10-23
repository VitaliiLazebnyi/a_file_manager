import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// Synchronize directories: the order of the walk, the cancel of blocked work, and committing before deleting.
@Suite
internal struct ToolsAdoptDirectorySync {
    /// A date in the past the files carry.
    internal let early = Date(timeIntervalSince1970: 1_000_000)

    /// A registry of `providers`.
    internal func registry(_ providers: any FileSystemProvider...) -> FileSystemRegistry {
        let registry = FileSystemRegistry()
        providers.forEach(registry.register)
        return registry
    }

    /// The order is the kernel's, with digits by value.
    ///
    /// (It was Foundation's localized comparison, which is no order and ends the program for
    /// certain names; for plain names the two agree, which the second half checks.).
    @Test
    internal func theWalkOrdersNamesAsTheSystemDoes() {
        var state: UInt64 = 7
        let alphabet = Array("aAbBzZ0019_.- \u{e9}(")
        func name() -> String {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var rest = state >> 20
            return String(
                (0..<Int(1 + state % 9))
                    .map { _ in
                        defer { rest = rest &* 31 &+ 17 }
                        return alphabet[Int((rest >> 5) % UInt64(alphabet.count))]
                    }
            )
        }
        let memory = MemoryFileSystem()
        let pairs = (0..<3_000)
            .map { index -> SyncComparison.Pair in
                let text = name()
                return SyncComparison.Pair(
                    name: text,
                    left: FileItem(url: memory.url("/" + String(index)), name: text),
                    right: nil
                )
            }
        let ordered = SyncComparison.sorted(pairs).map(\.name)
        for (one, two) in zip(ordered, ordered.dropFirst()) {
            #expect(Sorter.compare(one, two, numeric: true) != .orderedDescending)
        }
        #expect(ordered.count == pairs.count)
        // Names of letters and digits stand as the system has them: without regard to case, numbers by value.
        let plain = ["file10.txt", "File2.txt", "file1.txt", "b", "A", "a10", "a9", "Zebra", "apple"]
        let walked =
            SyncComparison.sorted(
                plain.enumerated()
                    .map { index, text in
                        SyncComparison.Pair(
                            name: text,
                            left: FileItem(url: memory.url("/p" + String(index)), name: text),
                            right: nil
                        )
                    }
            )
            .map(\.name)
        #expect(walked == ["A", "a9", "a10", "apple", "b", "file1.txt", "File2.txt", "file10.txt", "Zebra"])
        for (one, two) in zip(walked, walked.dropFirst()) {
            #expect(one.localizedStandardCompare(two) != .orderedDescending)
        }
    }

    /// The cancel ends a comparison that waits on a listing, and is no error.
    @Test
    internal func cancellingEndsABlockedListing() {
        let memory = MemoryFileSystem()
        memory.addFile("/L/a")
        memory.addFile("/R/a")
        let probe = ToolsAdopt.ProbingFileSystem(memory)
        memory.stallsListings = true
        defer { memory.releaseStalls() }
        let comparison = SyncComparison(options: SyncOptions(), fileSystems: registry(probe))
        let result = ToolsAdopt.Outcome<SyncResult>()
        let done = ToolsAdopt.background {
            result.value = comparison.run(left: memory.url("/L"), right: memory.url("/R"))
        }
        #expect(probe.listing.wait(timeout: .now() + Wait.ceiling) == .success)
        ToolsAdopt.cancelFromThread(comparison.cancellation)
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(result.value?.wasCancelled == true && result.value?.errors.isEmpty == true)
    }

    /// The cancel ends a comparison by content that waits on a read, and is no error.
    @Test
    internal func cancellingEndsABlockedComparisonByContent() {
        let memory = MemoryFileSystem()
        memory.addFile("/L/a", "same", modified: early)
        memory.addFile("/R/a", "same", modified: early)
        let probe = ToolsAdopt.ProbingFileSystem(memory)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        var options = SyncOptions()
        options.byContent = true
        let comparison = SyncComparison(options: options, fileSystems: registry(probe))
        let result = ToolsAdopt.Outcome<SyncResult>()
        let done = ToolsAdopt.background {
            result.value = comparison.run(left: memory.url("/L"), right: memory.url("/R"))
        }
        #expect(probe.reading.wait(timeout: .now() + Wait.ceiling) == .success)
        ToolsAdopt.cancelFromThread(comparison.cancellation)
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(result.value?.wasCancelled == true && result.value?.errors.isEmpty == true && memory.interruptions >= 1)
    }

    /// The cancel ends a run that waits on a read, and leaves no temporary file behind.
    @Test
    internal func cancellingEndsABlockedCopy() {
        let memory = MemoryFileSystem()
        memory.refusesInternalCopy = true
        memory.addFile("/L/new.txt", "data", modified: early)
        memory.addDirectory("/R")
        let probe = ToolsAdopt.ProbingFileSystem(memory)
        let registry = registry(probe)
        let plan = SyncPlan(
            rows: SyncComparison(options: SyncOptions(), fileSystems: registry)
                .run(
                    left: memory.url("/L"),
                    right: memory.url("/R")
                )
                .rows
        )
        #expect(plan.toRight.count == 1)
        memory.stallsReads = true
        defer { memory.releaseStalls() }
        let flag = CancellationFlag()
        let executor = SyncExecutor(plan: plan, options: SyncRunOptions(), fileSystems: registry, cancellation: flag)
        let outcome = ToolsAdopt.Outcome<SyncOutcome>()
        let done = ToolsAdopt.background { outcome.value = executor.run() }
        #expect(probe.reading.wait(timeout: .now() + Wait.ceiling) == .success)
        ToolsAdopt.cancelFromThread(flag)
        #expect(done.wait(timeout: .now() + Wait.ceiling) == .success)
        #expect(outcome.value?.wasCancelled == true && memory.interruptions >= 1)
        #expect(!memory.exists("/R/new.txt") && memory.allPaths.allSatisfy { !$0.contains("afm-sync") })
    }

    /// A file new on the left, a folder only there, and a file only on the right, on a file system that keeps
    /// writes back with `deferred`; with its registry.
    internal func syncSetup(deferred: Bool) -> (MemoryFileSystem, FileSystemRegistry) {
        let memory = MemoryFileSystem()
        memory.capabilities = deferred ? [.write, .deferredWrites] : [.write]
        memory.refusesInternalCopy = true
        memory.addFile("/L/new.txt", "from the left", modified: early.addingTimeInterval(500))
        memory.addDirectory("/L/folder")
        memory.addFile("/R/gone.txt", "only on the right", modified: early)
        return (memory, registry(memory))
    }

    /// The plan of the setup, with empty directories, the file only on the right to be deleted.
    internal func plan(_ memory: MemoryFileSystem, _ registry: FileSystemRegistry) -> SyncPlan {
        var options = SyncOptions()
        options.emptyDirectories = true
        var rows = SyncComparison(options: options, fileSystems: registry)
            .run(
                left: memory.url("/L"),
                right: memory.url("/R")
            )
            .rows
        for index in rows.indices where rows[index].name == "gone.txt" { rows[index].action = .deleteRight }
        return SyncPlan(rows: rows)
    }

    /// What was copied is made durable before anything is deleted, and keeps its mark and metadata.
    @Test
    internal func copiesAreCommittedBeforeDeletions() {
        let (memory, registry) = syncSetup(deferred: true)
        memory.quarantineValue = Data("0081;5f;Safari;".utf8)
        memory.keepsMetadata = true
        let plan = plan(memory, registry)
        #expect(plan.toRight.count == 2 && plan.deleteRight.count == 1)
        var options = SyncRunOptions()
        options.useTrash = false
        let outcome = SyncExecutor(plan: plan, options: options, fileSystems: registry).run()
        #expect(outcome.errors.isEmpty && outcome.copied == 2 && outcome.deleted == 1)
        #expect(!memory.commits.isEmpty && memory.commits.allSatisfy { $0 == "/" })
        #expect(memory.exists("/R/new.txt") && !memory.exists("/R/gone.txt"))
        // A file that came from elsewhere keeps saying so; a created folder carries its metadata.
        // (A file on a file system that keeps writes back is written under a temporary name and renamed, so the
        // mark and the metadata are put on the temporary, as the provider's contract says.)
        #expect(memory.quarantineMarks.values.contains(Data("0081;5f;Safari;".utf8)))
        #expect(Set(memory.metadataCopies.map(\.to)) == ["/R/folder", "/R/.new.txt.afm-sync"])
    }

    /// When the copies cannot be made durable nothing is deleted.
    @Test
    internal func aFailedCommitKeepsTheSources() {
        let (memory, registry) = syncSetup(deferred: true)
        struct Refused: Error {}
        memory.commitFailure = Refused()
        let outcome = SyncExecutor(plan: plan(memory, registry), options: SyncRunOptions(), fileSystems: registry).run()
        #expect(!outcome.errors.isEmpty && outcome.deleted == 0)
        #expect(memory.exists("/R/gone.txt"))
    }

    /// A file system that writes at once is not asked to commit.
    @Test
    internal func noCommitWhereWritesAreNotDeferred() {
        let (memory, registry) = syncSetup(deferred: false)
        _ = SyncExecutor(plan: plan(memory, registry), options: SyncRunOptions(), fileSystems: registry).run()
        #expect(memory.commits.isEmpty)
    }

    /// Whether the Trash is there is asked of the location of each deletion.
    @Test
    internal func trashIsAskedPerLocation() {
        let (memory, registry) = syncSetup(deferred: false)
        memory.capabilitiesAt = { _ in [.write, .trash] }
        let outcome = SyncExecutor(plan: plan(memory, registry), options: SyncRunOptions(), fileSystems: registry).run()
        // The memory file system has no Trash: asking for it fails, which shows the capability was consulted for the
        // location.
        #expect(outcome.deleted == 0 && !outcome.errors.isEmpty)
    }
}
