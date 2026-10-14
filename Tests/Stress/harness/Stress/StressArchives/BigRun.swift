import Foundation
import StressKit

@testable import ArchivesPlugin

// Scenario 5: archives. `--mode big` opens and lists the 200,000-member ZIP and then lets 16
// threads read 64 members (with random cancels) while one thread adds members and commits and
// another lists; after every commit the archive is checked with unzip, zipinfo and a fresh
// reader of the program's own.

/// The run of `--mode big` on `big.zip`.
internal final class BigRun: Sendable {
    /// The command line.
    internal let options: Options
    /// `big.zip`.
    internal let archive: URL
    /// The program's file systems, with the archive open for the whole run.
    internal let bench: Bench
    /// The archive's root in the writable scheme.
    internal let root: URL
    /// How many folders of 500 members the archive has.
    internal let folders: Int
    /// The members whose bytes the harness knows from the start.
    internal let probes: [Probe]

    /// Reads the probes and prepares the bench.
    internal init(options: Options) {
        self.options = options
        archive = options.directory.appendingPathComponent("big.zip")
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        say("big.zip: \(size >> 20) MB")
        probes = Probe.load(from: options.directory)
        say("probes: \(probes.count) members, \(probes.reduce(0) { $0 + $1.data.count } >> 20) MB")
        bench = Bench(flushDelay: 1)
        root = bench.inside(archive)
        folders = options.expectedEntries / 500
    }

    /// Runs every step; `baselineThreads` is what the process had before it.
    @MainActor
    internal func run(baselineThreads: Int) {
        openAndList()
        listAgain()
        listOneFolder()
        listEveryFolder()
        listEveryFolderAtOnce()
        askOnMain()
        readProbesOnce()
        let members = runConcurrentStage()
        finalChecks(members)
        step("close the store") { bench.store.close() }
        say(String(format: "MEM after closing the store: footprint=%.0f MB", footprintMB()))
        hazard()
        if options.runsLeaks {
            leaks()
        }
        settle(baselineThreads: baselineThreads)
        checkLeftovers()
    }

    /// The path of member `index` of the generated ones.
    internal func memberPath(_ index: Int) -> String {
        String(format: "dir%04d/f%06d.txt", index / 500, index)
    }

    /// The URL of folder `folder` of the generated ones.
    internal func folderURL(_ folder: Int) -> URL {
        bench.inside(archive, String(format: "dir%04d", folder))
    }

    deinit {
        // Nothing to release.
    }
}
