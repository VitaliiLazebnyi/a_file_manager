internal import AFMKernel
internal import Darwin
internal import Foundation
internal import LocalFileSystemPlugin
internal import StressKit
internal import TestSupport

@testable internal import FindFilesPlugin

/// Scenario 6, one run: the ground truth, the searches through the engine and through the window,
/// the cancelled ones, and the failures they found.
@MainActor
internal final class FindRun {
    /// The generated tree.
    internal let tree: URL
    /// The folder of a million files, when that part runs.
    internal let million: URL?
    /// How many searches each torture step cancels.
    internal let cancels: Int
    /// The plugin under test.
    internal let plugin = FindFilesPlugin()
    /// The kernel the plugin runs in, with the local file system and a small memory one.
    internal let bench: TestBench
    /// The kernel's file systems, for the engine.
    internal let fileSystems: FileSystemRegistry
    /// What failed, in order.
    internal private(set) var failures: [String] = []
    /// The searches and their truth.
    internal var cases: [SearchCase] = []
    /// The thread count while idle, after the ground truth.
    internal var baselineThreads = 0
    /// How many searches the window has finished.
    internal var finishedCount = 0
    /// How long each case took through the window, uncancelled.
    internal var typical: [String: Double] = [:]
    /// Picks the cases and the moments of the cancels.
    internal var random: Random

    /// The window controller, made when first used (after the engine runs, as a user would open it).
    internal lazy var window: FindFilesWindowController = {
        let controller = plugin.mainWindow(in: bench.kernel)
        controller.onFinished = { [weak self] in
            self?.finishedCount += 1
        }
        return controller
    }()

    /// A run over `tree` (and `million` when given) with `cancels` cancels per torture step.
    internal init(tree: URL, million: URL?, cancels: Int, seed: UInt64) {
        self.tree = tree
        self.million = million
        self.cancels = cancels
        random = Random(seed: seed)
        let memory = MemoryFileSystem()
        memory.addFile("/A/one.txt", "x")
        bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/A")
        )
        fileSystems = bench.kernel.fileSystems
    }

    /// Prints a line of the heap's figures after `label`.
    internal static func heapLine(_ label: String) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        let figures = String(
            format: " footprint %6.0f MB; malloc in use %6.0f MB, allocated from the system %6.0f MB; threads %d",
            footprintMB(),
            Double(stats.size_in_use) / 1_048_576,
            Double(stats.size_allocated) / 1_048_576,
            threadCount()
        )
        say("HEAP " + pad(label, 44) + figures)
    }

    /// Runs every part and prints the report; true when nothing failed.
    internal func runAll() -> Bool {
        groundTruth()
        step("idle baseline") { pump(for: 2) }
        baselineThreads = threadCount()
        say("threads at baseline: \(baselineThreads)")
        engineRuns()
        concurrentEngineRuns()
        Self.heapLine("after the engine runs")
        step("threads settle after engine runs") {
            let after = waitForThreads(atMost: baselineThreads + 2, upTo: 10)
            say("threads after engine runs: \(after) (baseline \(baselineThreads))")
        }
        windowRuns()
        cancelledWindowRuns()
        Self.heapLine("after the window's cancelled searches")
        cancelledEngineRuns()
        Self.heapLine("after the engine's cancelled runs")
        threadsSettle()
        windowRunsAfterTorture()
        Self.heapLine("at the end")
        if ProcessInfo.processInfo.environment["STRESS_TEXT_LOOP"] != nil {
            textSearchLoop()
        }
        MainWatchdog.shared.report(title: "scenario 6, Find Files")
        say("\nFAILURES: \(failures.count)")
        for failure in failures.prefix(40) {
            say("  " + failure)
        }
        say(String(format: "peak RSS %.0f MB, threads %d, load %.1f", peakRSSMB(), threadCount(), loadAverage()))
        return failures.isEmpty
    }

    /// Records a failure and prints it.
    internal func fail(_ text: String) {
        failures.append(text)
        say("FAIL: " + text)
    }

    /// Fails when `items` hold duplicates or are not exactly `expected` (files only when `filesOnly`).
    internal func verify(_ label: String, _ items: [FileItem], against expected: Set<String>, filesOnly: Bool) {
        MainWatchdog.shared.setPhase("(harness: checking results)")
        // "all" also finds the folders; the truth lists files.
        let paths = items.filter { !filesOnly || !$0.isDirectory }.map(\.url.path)
        let unique = Set(paths)
        if unique.count != paths.count {
            fail("\(label): \(paths.count - unique.count) duplicate results")
        }
        if unique != expected {
            let missing = expected.subtracting(unique)
            let extra = unique.subtracting(expected)
            fail(
                "\(label): expected \(expected.count), got \(unique.count); "
                    + "missing \(missing.count) e.g. \(missing.prefix(2)), extra \(extra.count) e.g. \(extra.prefix(2))"
            )
        }
    }

    /// Finds the truth of every case: the tree's, and the million folder's when given.
    private func groundTruth() {
        step("ground truth: tree") {
            let files = GroundTruth.allFiles(tree)
            say("tree: \(files.count) files")
            let txt = Set(files.filter { $0.hasSuffix(".txt") })
            // The search is not case sensitive by default.
            let withNeedle = GroundTruth.parallelFilter(files) { path in
                GroundTruth.contains(path, FindTree.needle, caseInsensitive: true)
            }
            cases.append(SearchCase(label: "tree name *.txt", directory: tree, names: "*.txt", text: "", expected: txt))
            cases.append(
                SearchCase(
                    label: "tree text NEEDLE",
                    directory: tree,
                    names: "",
                    text: FindTree.needle,
                    expected: withNeedle
                )
            )
            say("tree: *.txt \(txt.count), with needle \(withNeedle.count)")
        }
        if let million {
            step("ground truth: million") {
                millionTruth(million)
            }
        }
    }

    /// The truth of the three searches of the million folder.
    private func millionTruth(_ million: URL) {
        let files = GroundTruth.allFiles(million)
        say("million: \(files.count) files")
        let png = Set(files.filter { $0.hasSuffix("7.png") })
        let nonEmpty = files.filter { path in
            var info = stat()
            return lstat(path, &info) == 0 && info.st_size >= 4
        }
        let withText = GroundTruth.parallelFilter(nonEmpty) { path in
            GroundTruth.contains(path, "xxxx", caseInsensitive: true)
        }
        cases.append(
            SearchCase(label: "million name *7.png", directory: million, names: "*7.png", text: "", expected: png)
        )
        cases.append(
            SearchCase(label: "million text xxxx", directory: million, names: "", text: "xxxx", expected: withText)
        )
        cases.append(
            SearchCase(label: "million name * (all)", directory: million, names: "", text: "", expected: Set(files))
        )
        say("million: *7.png \(png.count), with xxxx \(withText.count), all files \(files.count)")
    }

    deinit {
        // Nothing to release.
    }
}
