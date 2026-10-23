import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport

@testable import DirectorySyncPlugin

/// Two trees in memory to plan and carry out: a new file and a newer one on the left, a newer one and one in
/// a subfolder on the right, and an equal pair.
internal struct SyncRunFixture {
    /// The date the files are dated from.
    internal static let early = Date(timeIntervalSince1970: 1_000_000)

    /// The local and the memory file system.
    internal let fileSystems = FileSystemRegistry()
    /// The trees `/L` and `/R`.
    internal let memory = MemoryFileSystem()

    /// The two trees.
    internal init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
        memory.addFile("/L/new.txt", "from the left", modified: Self.early.addingTimeInterval(500))
        memory.addFile("/L/update.txt", "newer on the left", modified: Self.early.addingTimeInterval(60))
        memory.addFile("/R/update.txt", "older", modified: Self.early)
        memory.addFile("/L/back.txt", "older", modified: Self.early)
        memory.addFile("/R/back.txt", "newer on the right", modified: Self.early.addingTimeInterval(60))
        memory.addFile("/R/sub/deep/arrives.txt", "from the right", modified: Self.early.addingTimeInterval(7))
        memory.addFile("/L/same.txt", "same", modified: Self.early)
        memory.addFile("/R/same.txt", "same", modified: Self.early)
    }

    /// The usual run options: what `SyncRunOptions` starts with.
    private static func usual(_: inout SyncRunOptions) {
        // As they are.
    }

    /// An executor as it is made, with no callbacks set.
    private static func asMade(_: SyncExecutor) {
        // Nothing to set up.
    }

    /// The rows of a comparison of the trees by the usual options.
    internal func rows() -> [SyncRow] {
        rows { _ in
            // The usual options.
        }
    }

    /// The rows of a comparison of the trees by the options `configure` makes.
    internal func rows(_ configure: (inout SyncOptions) -> Void) -> [SyncRow] {
        var options = SyncOptions()
        configure(&options)
        return SyncComparison(options: options, fileSystems: fileSystems)
            .run(left: memory.url("/L"), right: memory.url("/R"))
            .rows
    }

    /// Carries out the plan without confirming overwrites.
    @discardableResult
    internal func run(_ plan: SyncPlan) -> SyncOutcome {
        execute(plan, confirming: false, prepare: Self.asMade, options: Self.usual)
    }

    /// Carries out the plan by an executor that `prepare` sets up, without confirming overwrites.
    @discardableResult
    internal func run(_ plan: SyncPlan, _ prepare: (SyncExecutor) -> Void) -> SyncOutcome {
        execute(plan, confirming: false, prepare: prepare, options: Self.usual)
    }

    /// Carries out the plan by an executor that `prepare` sets up, confirming overwrites or not.
    @discardableResult
    internal func run(_ plan: SyncPlan, confirming: Bool, _ prepare: (SyncExecutor) -> Void) -> SyncOutcome {
        execute(plan, confirming: confirming, prepare: prepare, options: Self.usual)
    }

    /// Carries out the plan by the run options `configure` makes, without confirming overwrites.
    @discardableResult
    internal func runWithOptions(_ plan: SyncPlan, _ configure: (inout SyncRunOptions) -> Void) -> SyncOutcome {
        execute(plan, confirming: false, prepare: Self.asMade, options: configure)
    }

    /// Carries out the plan: the run options are made by `configure`, the executor is set up by `prepare`.
    private func execute(
        _ plan: SyncPlan,
        confirming: Bool,
        prepare: (SyncExecutor) -> Void,
        options configure: (inout SyncRunOptions) -> Void
    ) -> SyncOutcome {
        var options = SyncRunOptions()
        options.confirmOverwrites = confirming
        configure(&options)
        let executor = SyncExecutor(plan: plan, options: options, fileSystems: fileSystems)
        prepare(executor)
        return executor.run()
    }
}
