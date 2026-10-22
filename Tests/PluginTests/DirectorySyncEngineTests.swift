import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import DirectorySyncPlugin

private let early = Date(timeIntervalSince1970: 1_000_000)

/// The rows as short texts: `sub/name state action`.
private func describe(_ rows: [SyncRow]) -> [String] {
    rows.map { "\($0.relativePath)\($0.isDirectory ? "/" : "") \($0.state) \($0.action)" }
}

/// The comparison engine over trees in memory and on disk (spec 09 › Comparison algorithm).
@Suite
struct SyncComparing {
    let fileSystems = FileSystemRegistry()
    let memory = MemoryFileSystem()

    init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
    }

    func compare(_ left: String = "/L", _ right: String = "/R", _ configure: (inout SyncOptions) -> Void = { _ in })
        -> SyncResult
    {
        var options = SyncOptions()
        configure(&options)
        return SyncComparison(options: options, fileSystems: fileSystems)
            .run(
                left: memory.url(left),
                right: memory.url(right)
            )
    }

    /// One file of every kind the comparison tells apart.
    func makeTree() {
        memory.addFile("/L/equal.txt", "same", modified: early)
        memory.addFile("/R/equal.txt", "same", modified: early)
        memory.addFile("/L/left.txt", "only here")
        memory.addFile("/R/right.txt", "only there")
        memory.addFile("/L/newer-left.txt", "new", modified: early.addingTimeInterval(60))
        memory.addFile("/R/newer-left.txt", "old", modified: early)
        memory.addFile("/L/newer-right.txt", "old", modified: early)
        memory.addFile("/R/newer-right.txt", "newer", modified: early.addingTimeInterval(60))
        memory.addFile("/L/size.txt", "short", modified: early)
        memory.addFile("/R/size.txt", "much longer", modified: early)
        memory.addFile("/L/twin.txt", "aaaa", modified: early)
        memory.addFile("/R/twin.txt", "bbbb", modified: early)
        memory.addFile("/L/sub/deep/inner.txt", "x", modified: early)
        memory.addFile("/R/sub/deep/inner.txt", "x", modified: early)
        memory.addFile("/L/sub/only-left.txt", "x")
        memory.addFile("/R/other/only-right.txt", "x")
    }

    @Test
    func namesThatDifferOnlyInUnicodeFormKeepTheirOwnRows() {
        let (composed, decomposed) = ("caf\u{E9}.txt", "cafe\u{301}.txt")
        for side in ["/L", "/R"] {
            memory.addFile(side + "/" + composed, side == "/L" ? "left composed" : "right composed", modified: early)
            memory.addFile(
                side + "/" + decomposed,
                side == "/L" ? "left decomposed" : "right decomposed",
                modified: early
            )
        }
        // A twin that only one side holds, in the other form, is the same name to that side.
        memory.addFile("/L/\u{FC}ber.txt", "same", modified: early)
        memory.addFile("/R/u\u{308}ber.txt", "same", modified: early)
        let rows = compare().rows
        let cafe = rows.filter { $0.relativePath.hasPrefix("caf") }
        #expect(cafe.count == 2 && Set(cafe.map { Array($0.relativePath.utf8) }).count == 2)
        #expect(cafe.allSatisfy { $0.left != nil && $0.right != nil })
        #expect(rows.count == 3 && rows.first { $0.relativePath.hasSuffix("ber.txt") }?.state == .equal)

        // Only one spelling asked for: the twin of it on the same side is not taken along.
        let only = compare("/L", "/R") { $0.onlyNames = [composed] }.rows
        #expect(only.count == 1 && Array(only[0].relativePath.utf8) == Array(composed.utf8))
        let alike = compare("/L", "/R") { $0.onlyNames = ["u\u{308}ber.txt"] }.rows
        #expect(alike.count == 1 && alike[0].state == .equal)
    }

    @Test
    func statesAndDefaultDirections() {
        makeTree()
        let result = compare()
        #expect(
            describe(result.rows) == [
                "equal.txt equal none", "left.txt leftOnly copyToRight", "newer-left.txt leftNewer copyToRight",
                "newer-right.txt rightNewer copyToLeft", "right.txt rightOnly copyToLeft", "size.txt different none",
                "twin.txt equal none",
                "other/only-right.txt rightOnly copyToLeft", "sub/only-left.txt leftOnly copyToRight",
                "sub/deep/inner.txt equal none"
            ]
        )
        #expect(result.errors.isEmpty && !result.wasCancelled)
        // /L, /L/sub, /L/sub/deep on the left; /R, /R/other, /R/sub, /R/sub/deep on the right.
        #expect(result.leftDirectories == 3 && result.rightDirectories == 4)
        #expect(
            SyncSummary(result.rows).text
                == "Files found: 10  (Identical: 3, Different: 3, Unique left: 2, Unique right: 2)"
        )
        #expect(SyncSummary([]).text == "Files found: 0")
    }

    @Test
    func withoutSubdirectoriesOnlyTheStartFolders() {
        makeTree()
        let rows = compare { $0.subdirectories = false }.rows
        #expect(rows.count == 7 && rows.allSatisfy { $0.directory.isEmpty })
    }

    @Test
    func byContentReadsPairsThatLookEqual() {
        makeTree()
        let result = compare { $0.byContent = true }
        let states = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.relativePath, $0.state) })
        #expect(
            states["twin.txt"] == .different && states["equal.txt"] == .equal && states["sub/deep/inner.txt"] == .equal
        )
        #expect(states["newer-left.txt"] == .leftNewer && states["size.txt"] == .different)
        #expect(!result.rows.contains { $0.state == .pending })
    }

    @Test
    func ignoreDateKnowsOnlyEqualAndDifferent() {
        makeTree()
        memory.addFile("/L/dated.txt", "1234", modified: early)
        memory.addFile("/R/dated.txt", "abcd", modified: early.addingTimeInterval(9_999))
        var states = Dictionary(
            uniqueKeysWithValues: compare { $0.ignoreDate = true }.rows.map { ($0.relativePath, $0) }
        )
        #expect(states["dated.txt"]?.state == .equal)
        // Same length, different dates: only the size counts.
        #expect(states["newer-left.txt"]?.state == .equal && states["newer-right.txt"]?.state == .different)
        #expect(states["newer-right.txt"]?.action == SyncAction.none)
        states = Dictionary(
            uniqueKeysWithValues: compare {
                $0.ignoreDate = true
                $0.byContent = true
            }
            .rows.map { ($0.relativePath, $0) }
        )
        #expect(
            states["dated.txt"]?.state == .different && states["newer-left.txt"]?.state == .different
                && states["equal.txt"]?.state == .equal
        )
    }

    @Test
    func asymmetricDeletesOnTheRightAndNeverCopiesLeft() {
        makeTree()
        let rows = compare { $0.asymmetric = true }.rows
        let actions = Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0.action) })
        #expect(actions["right.txt"] == .deleteRight && actions["other/only-right.txt"] == .deleteRight)
        #expect(actions["newer-right.txt"] == SyncAction.none && actions["left.txt"] == .copyToRight)
        #expect(!rows.contains { $0.action == .copyToLeft })
    }

    @Test
    func dateTolerances() {
        func state(_ seconds: TimeInterval, _ configure: (inout SyncOptions) -> Void = { _ in }) -> SyncState {
            var options = SyncOptions()
            configure(&options)
            let left = FileItem(
                url: memory.url("/a"),
                name: "a",
                stat: .init(size: 1, modified: early.addingTimeInterval(seconds))
            )
            let right = FileItem(url: memory.url("/b"), name: "a", stat: .init(size: 1, modified: early))
            return SyncComparison.classify(left: left, right: right, options: options).state
        }
        #expect(state(3) == .equal && state(-3) == .equal && state(4) == .leftNewer && state(-4) == .rightNewer)
        #expect(state(2) { $0.toleranceSeconds = 2 } == .equal && state(3) { $0.toleranceSeconds = 2 } == .leftNewer)
        #expect(state(1) { $0.toleranceSeconds = 0 } == .leftNewer && state(0) { $0.toleranceSeconds = 0 } == .equal)
        #expect(state(3_600) == .leftNewer && state(3_600) { $0.ignoreOneHourDifference = true } == .equal)
        #expect(
            state(-3_602) { $0.ignoreOneHourDifference = true } == .equal
                && state(7_200) { $0.ignoreOneHourDifference = true } == .leftNewer
        )
        // The right side is two hours behind: its dates are moved before comparing.
        #expect(state(7_200) { $0.timeOffsetHours = 2 } == .equal && state(0) { $0.timeOffsetHours = 2 } == .rightNewer)
        #expect(
            SyncComparison.classify(
                left: FileItem(url: memory.url("/a"), name: "a", stat: .init(size: 1, modified: early)),
                right: FileItem(url: memory.url("/b"), name: "a", stat: .init(size: 1, modified: early)),
                options: {
                    var options = SyncOptions()
                    options.byContent = true
                    return options
                }()
            )
            .needsContent
        )
    }

    @Test
    func masksWithExclusions() {
        #expect(SyncMask("*.txt *.md").matchesFile("a.MD") && !SyncMask("*.txt").matchesFile("a.md"))
        #expect(SyncMask("*.* | *.bak;~*").matchesFile("a.txt") && !SyncMask("*.* | *.bak;~*").matchesFile("~a.txt"))
        #expect(
            SyncMask("").matchesFile("anything") && SyncMask("| *.o").matchesFile("a.c")
                && !SyncMask("| *.o").matchesFile("a.o")
        )
        #expect(
            SyncMask("*.* | build/ .git/").excludesFolder("build") && !SyncMask("*.* | build/").excludesFolder("src")
        )
        #expect(SyncMask("*.* | build/").matchesFile("build"))

        makeTree()
        #expect(
            describe(compare { $0.mask = "*.txt | newer* sub/" }.rows) == [
                "equal.txt equal none", "left.txt leftOnly copyToRight", "right.txt rightOnly copyToLeft",
                "size.txt different none",
                "twin.txt equal none", "other/only-right.txt rightOnly copyToLeft"
            ]
        )
        #expect(compare { $0.mask = "*.md" }.rows.isEmpty)
    }

    @Test
    func onlySelectedNamesOfTheStartFolders() {
        makeTree()
        let rows = compare { $0.onlyNames = ["left.txt", "sub", "right.txt"] }.rows
        #expect(
            describe(rows) == [
                "left.txt leftOnly copyToRight", "right.txt rightOnly copyToLeft",
                "sub/only-left.txt leftOnly copyToRight", "sub/deep/inner.txt equal none"
            ]
        )
    }

    @Test
    func emptyDirectoriesAreRowsOfTheirOwn() {
        memory.addDirectory("/L/empty")
        memory.addDirectory("/L/both")
        memory.addDirectory("/R/both")
        memory.addFile("/R/gone/file.txt")
        #expect(describe(compare().rows) == ["gone/file.txt rightOnly copyToLeft"])
        #expect(
            describe(compare { $0.emptyDirectories = true }.rows)
                == ["empty/ leftOnly copyToRight", "gone/ rightOnly copyToLeft", "gone/file.txt rightOnly copyToLeft"]
        )
        let asymmetric = compare {
            $0.emptyDirectories = true
            $0.asymmetric = true
        }
        .rows
        #expect(
            describe(asymmetric) == [
                "empty/ leftOnly copyToRight", "gone/ rightOnly deleteRight", "gone/file.txt rightOnly deleteRight"
            ]
        )
        #expect(SyncSummary(asymmetric).files == 1)
    }

    @Test
    func namesThatDifferInCaseAndFilesFacingFoldersAreExcluded() {
        memory.addFile("/L/Readme.txt", "a")
        memory.addFile("/R/README.TXT", "a")
        memory.addFile("/L/thing", "a file")
        memory.addFile("/R/thing/inside.txt", "a folder")
        memory.addFile("/L/Docs/a.txt", "a")
        memory.addFile("/R/docs/a.txt", "a")
        memory.addFile("/R/docs/b.txt", "b")
        let rows = compare().rows
        #expect(
            describe(rows) == [
                "Readme.txt excluded none", "thing excluded none", "Docs/a.txt equal none",
                "Docs/b.txt rightOnly copyToLeft"
            ]
        )
        #expect(!rows[0].accepts(.copyToRight) && !rows[1].accepts(.deleteBoth) && rows[0].accepts(.none))
        // Folders that differ only in case are one folder, and each side keeps its own spelling.
        #expect(rows[3].leftURL.path == "/L/Docs/b.txt" && rows[3].rightURL.path == "/R/docs/b.txt")
    }

    @Test
    func aFolderThatCannotBeReadIsLeftOutOnBothSides() {
        makeTree()
        memory.unreadable = ["/R/sub"]
        let result = compare { $0.asymmetric = true }
        #expect(result.errors.count == 1 && result.errors[0].contains("/R/sub"))
        // Nothing below it may look unique, or it would be copied or deleted for no reason.
        #expect(!result.rows.contains { $0.directory.hasPrefix("sub/") })
        #expect(result.rows.contains { $0.relativePath == "left.txt" })
    }

    @Test
    func cancelledComparisonStopsAndSaysSo() {
        makeTree()
        let comparison = SyncComparison(options: SyncOptions(), fileSystems: fileSystems)
        comparison.cancellation.cancel()
        let result = comparison.run(left: memory.url("/L"), right: memory.url("/R"))
        #expect(result.wasCancelled && result.rows.isEmpty)

        // Cancelled while comparing by content: the pairs not read stay undecided.
        var options = SyncOptions()
        options.byContent = true
        let second = SyncComparison(options: options, fileSystems: fileSystems)
        let afterWalk = second.run(left: memory.url("/L"), right: memory.url("/R")) { progress in
            if progress.filesToCompare > 0 { second.cancellation.cancel() }
        }
        #expect(afterWalk.wasCancelled && afterWalk.rows.contains { $0.state == .pending && $0.action == .none })
    }

    @Test
    func aFinishedComparisonIsLetGo() {
        makeTree()
        weak var finished: SyncComparison?
        do {
            let comparison = SyncComparison(options: SyncOptions(), fileSystems: fileSystems)
            // The progress holds the comparison, as that of a caller who may cancel it does.
            let result = comparison.run(left: memory.url("/L"), right: memory.url("/R")) { _ in
                _ = comparison.cancellation.isCancelled
            }
            #expect(!result.rows.isEmpty)
            finished = comparison
        }
        #expect(finished == nil)
    }

    @Test
    func everyCombinationOfOptionsKeepsItsPromises() {
        makeTree()
        memory.addDirectory("/L/hollow")
        for bits in 0..<32 {
            let result = compare {
                $0.subdirectories = bits & 1 != 0
                $0.byContent = bits & 2 != 0
                $0.ignoreDate = bits & 4 != 0
                $0.asymmetric = bits & 8 != 0
                $0.emptyDirectories = bits & 16 != 0
            }
            let rows = result.rows
            #expect(rows.allSatisfy { $0.accepts($0.action) && $0.action == $0.defaultAction }, "options \(bits)")
            #expect(rows.allSatisfy { $0.state != .pending }, "options \(bits)")
            #expect((bits & 1 != 0) || rows.allSatisfy { $0.directory.isEmpty && !$0.isDirectory }, "options \(bits)")
            #expect(
                (bits & 4 == 0) || !rows.contains { $0.state == .leftNewer || $0.state == .rightNewer },
                "options \(bits)"
            )
            #expect((bits & 8 == 0) || !rows.contains { $0.action == .copyToLeft }, "options \(bits)")
            #expect((bits & 8 != 0) || !rows.contains { $0.action == .deleteRight }, "options \(bits)")
            #expect(rows.contains { $0.isDirectory } == (bits & 17 == 17), "options \(bits)")
            let twin = rows.first { $0.name == "twin.txt" }?.state
            #expect(twin == (bits & 2 != 0 ? .different : .equal), "options \(bits)")
            #expect(Set(rows.map(\.relativePath)).count == rows.count, "options \(bits)")
        }
    }

    @Test
    func manyPairsAreComparedOnAllCoresAndStayInOrder() {
        for index in 0..<300 {
            let name = String(format: "d%02d/f%03d.bin", index % 12, index)
            memory.addFile("/L/" + name, String(repeating: "a", count: 2_000) + "\(index)", modified: early)
            memory.addFile(
                "/R/" + name,
                String(repeating: "a", count: 2_000)
                    + (index % 7 == 0 ? "x" : "\(index)")
                    .padding(
                        toLength: "\(index)".count,
                        withPad: "x",
                        startingAt: 0
                    ),
                modified: early
            )
        }
        var options = SyncOptions()
        options.byContent = true
        let comparison = SyncComparison(options: options, fileSystems: fileSystems)
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var last = SyncProgress()
        let result = comparison.run(left: memory.url("/L"), right: memory.url("/R")) { progress in
            lock.lock()
            last = progress
            lock.unlock()
        }
        #expect(result.rows.count == 300)
        #expect(result.rows.map(\.relativePath) == result.rows.map(\.relativePath).sorted())
        for row in result.rows {
            let index = Int(row.name.dropFirst().prefix(3)) ?? -1
            #expect(row.state == (index % 7 == 0 ? .different : .equal), "\(row.name)")
        }
        #expect(
            last.filesCompared == 300 && last.filesToCompare == 300 && last.bytesCompared > 0
                && last.leftDirectories == 13
        )
    }

    @Test
    func comparesAcrossFileSystemsAndIgnoresLinks() throws {
        let box = try Sandbox()
        try box.file("L/same.txt", "identical bytes", modified: early)
        try box.file("L/changed.txt", "left bytes!", modified: early)
        try box.file("L/target.txt", "x", modified: early)
        try FileManager.default.createSymbolicLink(
            at: box.url("L/link.txt"),
            withDestinationURL: box.url("L/target.txt")
        )
        try FileManager.default.createSymbolicLink(at: box.url("L/loop"), withDestinationURL: box.url("L"))
        memory.addFile("/R/same.txt", "identical bytes", modified: early)
        memory.addFile("/R/changed.txt", "right bytes", modified: early)
        var options = SyncOptions()
        options.byContent = true
        let result = SyncComparison(options: options, fileSystems: fileSystems)
            .run(
                left: box.url("L"),
                right: memory.url("/R")
            )
        #expect(
            describe(result.rows) == [
                "changed.txt different none", "same.txt equal none", "target.txt leftOnly copyToRight"
            ]
        )
    }

    @Test
    func streamsOfUnevenBlocksCompareCorrectly() throws {
        let big = String(repeating: "0123456789", count: 70_000)
        memory.addFile("/a", big)
        memory.addFile("/b", big)
        memory.addFile("/c", big.dropLast() + "!")
        memory.addFile("/d", big + "tail")
        let flag = CancellationFlag()
        var bytes = 0
        #expect(
            try SyncComparison.sameContent(
                memory.url("/a"),
                memory.url("/b"),
                fileSystems: fileSystems,
                cancellation: flag
            ) { bytes += $0 } == true
        )
        #expect(bytes == 700_000)
        #expect(
            try SyncComparison.sameContent(
                memory.url("/a"),
                memory.url("/c"),
                fileSystems: fileSystems,
                cancellation: flag
            ) == false
        )
        #expect(
            try SyncComparison.sameContent(
                memory.url("/a"),
                memory.url("/d"),
                fileSystems: fileSystems,
                cancellation: flag
            ) == false
        )
        #expect(throws: (any Error).self) {
            try SyncComparison.sameContent(
                memory.url("/a"),
                memory.url("/missing"),
                fileSystems: fileSystems,
                cancellation: flag
            )
        }
    }

    @Test
    func showButtonsFilterByComputedDirection() {
        makeTree()
        let rows = compare().rows
        func shown(_ show: SyncShow) -> [String] { rows.filter(show.shows).map(\.name) }
        #expect(shown(.all).count == rows.count)
        #expect(shown([.copyToRight, .duplicates, .singles]) == ["left.txt", "newer-left.txt", "only-left.txt"])
        #expect(shown([.copyToLeft, .duplicates, .singles]) == ["newer-right.txt", "right.txt", "only-right.txt"])
        #expect(shown([.equal, .duplicates, .singles]) == ["equal.txt", "twin.txt", "inner.txt"])
        #expect(shown([.notEqual, .duplicates, .singles]) == ["size.txt"])
        #expect(
            shown(SyncShow.all.subtracting(.singles)).count == 6
                && shown(SyncShow.all.subtracting(.duplicates)).count == 4
        )
        #expect(shown([.duplicates, .singles]).isEmpty)
    }

    @Test
    func actionsARowAccepts() {
        makeTree()
        let rows = Dictionary(uniqueKeysWithValues: compare().rows.map { ($0.name, $0) })
        let (left, right, pair) = (rows["left.txt"]!, rows["right.txt"]!, rows["size.txt"]!)
        #expect(
            left.accepts(.copyToRight) && left.accepts(.deleteLeft) && !left.accepts(.copyToLeft)
                && !left.accepts(.deleteRight) && !left.accepts(.deleteBoth)
        )
        #expect(right.accepts(.copyToLeft) && right.accepts(.deleteRight) && !right.accepts(.copyToRight))
        #expect(pair.accepts(.copyToLeft) && pair.accepts(.copyToRight) && pair.accepts(.deleteBoth))
        // A click goes through what is possible: nothing, right, left for a pair without default.
        var clicked = pair
        var seen: [SyncAction] = []
        for _ in 0..<3 {
            clicked.action = clicked.nextAction
            seen.append(clicked.action)
        }
        #expect(seen == [.copyToRight, .copyToLeft, .none])
        #expect(left.nextAction == SyncAction.none)
        var reversed = rows["newer-left.txt"]!
        reversed.action = reversed.reversedAction
        #expect(reversed.action == .copyToLeft && left.reversedAction == .copyToRight)
    }
}

/// Planning and carrying out (spec 09 › The "Synchronize" dialog and the run).
@Suite
struct SyncExecuting {
    let fileSystems = FileSystemRegistry()
    let memory = MemoryFileSystem()

    init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
        memory.addFile("/L/new.txt", "from the left", modified: early.addingTimeInterval(500))
        memory.addFile("/L/update.txt", "newer on the left", modified: early.addingTimeInterval(60))
        memory.addFile("/R/update.txt", "older", modified: early)
        memory.addFile("/L/back.txt", "older", modified: early)
        memory.addFile("/R/back.txt", "newer on the right", modified: early.addingTimeInterval(60))
        memory.addFile("/R/sub/deep/arrives.txt", "from the right", modified: early.addingTimeInterval(7))
        memory.addFile("/L/same.txt", "same", modified: early)
        memory.addFile("/R/same.txt", "same", modified: early)
    }

    func rows(_ configure: (inout SyncOptions) -> Void = { _ in }) -> [SyncRow] {
        var options = SyncOptions()
        configure(&options)
        return SyncComparison(options: options, fileSystems: fileSystems)
            .run(
                left: memory.url("/L"),
                right: memory.url("/R")
            )
            .rows
    }

    @discardableResult
    func run(
        _ plan: SyncPlan,
        confirming: Bool = false,
        _ prepare: (SyncExecutor) -> Void = { _ in },
        options configure: (inout SyncRunOptions) -> Void = { _ in }
    ) -> SyncOutcome {
        var options = SyncRunOptions()
        options.confirmOverwrites = confirming
        configure(&options)
        let executor = SyncExecutor(plan: plan, options: options, fileSystems: fileSystems)
        prepare(executor)
        return executor.run()
    }

    @Test
    func planCountsWhatTheRowsAsk() {
        let plan = SyncPlan(rows: rows())
        #expect(plan.toRight.map(\.relativePath) == ["new.txt", "update.txt"])
        #expect(plan.toLeft.map(\.relativePath) == ["back.txt", "sub/deep/arrives.txt"])
        #expect(plan.deleteLeft.isEmpty && plan.deleteRight.isEmpty && !plan.isEmpty)
        #expect(SyncPlan.describe(plan.toRight) == "Copy 2 files, total size: 30 bytes")
        #expect(plan.toLeft[1].target.path == "/L/sub/deep/arrives.txt")
        #expect(SyncPlan(rows: rows().filter { $0.state == .equal }).isEmpty)

        var changed = rows()
        for index in changed.indices {
            switch changed[index].name {
            case "same.txt":
                changed[index].action = .deleteBoth

            case "new.txt":
                changed[index].action = .deleteLeft

            case "update.txt":
                changed[index].action = .copyToLeft

            // What a row cannot do is not planned.
            case "arrives.txt":
                changed[index].action = .copyToRight

            default:
                changed[index].action = .none
            }
        }
        let second = SyncPlan(rows: changed)
        #expect(second.toRight.isEmpty && second.toLeft.map(\.relativePath) == ["update.txt"])
        #expect(
            second.deleteLeft.map(\.url.lastPathComponent) == ["new.txt", "same.txt"]
                && second.deleteRight.map(\.url.lastPathComponent) == ["same.txt"]
        )
    }

    @Test
    func bothDirectionsArriveWithTheirDatesAndTheSidesAreEqualAfterwards() {
        var progress: [JobProgress] = []
        let outcome = run(SyncPlan(rows: rows())) { $0.onProgress = { progress.append($0) } }
        #expect(outcome.copied == 4 && outcome.skipped == 0 && outcome.errors.isEmpty && !outcome.wasCancelled)
        #expect(
            memory.contents("/R/new.txt") == "from the left" && memory.contents("/R/update.txt") == "newer on the left"
        )
        #expect(
            memory.contents("/L/back.txt") == "newer on the right"
                && memory.contents("/L/sub/deep/arrives.txt") == "from the right"
        )
        #expect(memory.item(at: memory.url("/R/new.txt"))?.modified == early.addingTimeInterval(500))
        #expect(memory.item(at: memory.url("/L/sub/deep/arrives.txt"))?.modified == early.addingTimeInterval(7))
        // No temporary file stays behind.
        #expect(
            memory.allPaths == [
                "/L", "/L/back.txt", "/L/new.txt", "/L/same.txt", "/L/sub", "/L/sub/deep", "/L/sub/deep/arrives.txt",
                "/L/update.txt", "/R", "/R/back.txt", "/R/new.txt", "/R/same.txt", "/R/sub", "/R/sub/deep",
                "/R/sub/deep/arrives.txt", "/R/update.txt"
            ]
        )
        #expect(Set(outcome.changedDirectories.map(\.path)) == ["/L", "/R", "/L/sub/deep"])
        // Right to left runs first (spec 09 › Running it).
        #expect(
            progress.first?.lines.first == "Right -> Left  (1 / 2)"
                && progress.last?.lines.first?.hasPrefix("Left -> Right") == true
        )
        #expect(progress.last?.itemsTotal == 4 && progress.last?.bytesTotal == 62)
        #expect(rows { $0.byContent = true }.allSatisfy { $0.state == .equal })
    }

    @Test
    func overwritesAreConfirmedPerFile() {
        var asked: [String] = []
        var outcome = run(SyncPlan(rows: rows()), confirming: true) { executor in
            executor.onOverwrite = { target, copy in
                asked.append("\(target.name) \(copy.size)")
                return target.name == "back.txt" ? .skip : .overwrite
            }
        }
        #expect(asked == ["back.txt 18", "update.txt 17"])
        #expect(outcome.copied == 3 && outcome.skipped == 1 && memory.contents("/L/back.txt") == "older")

        // "Skip All" leaves every existing target alone but still brings the new files.
        memory.addFile("/R/update.txt", "older", modified: early)
        memory.removeTree("/R/new.txt")
        outcome = run(SyncPlan(rows: rows()), confirming: true) { $0.onOverwrite = { _, _ in .skipAll } }
        #expect(
            outcome.copied == 1 && outcome.skipped == 2 && memory.contents("/R/update.txt") == "older"
                && memory.exists("/R/new.txt")
        )

        asked = []
        outcome = run(SyncPlan(rows: rows()), confirming: true) { executor in
            executor.onOverwrite = { target, _ in
                asked.append(target.name)
                return .overwriteAll
            }
        }
        #expect(asked == ["back.txt"] && outcome.copied == 2 && memory.contents("/R/update.txt") == "newer on the left")
    }

    @Test
    func cancellingAtAQuestionStopsTheRun() {
        let outcome = run(SyncPlan(rows: rows()), confirming: true) { $0.onOverwrite = { _, _ in .cancel } }
        #expect(outcome.wasCancelled && outcome.copied == 0)
        #expect(memory.contents("/L/back.txt") == "older" && !memory.exists("/R/new.txt") && !memory.exists("/L/sub"))

        let flag = CancellationFlag()
        flag.cancel()
        let second = SyncExecutor(
            plan: SyncPlan(rows: rows()),
            options: SyncRunOptions(),
            fileSystems: fileSystems,
            cancellation: flag
        )
        .run()
        #expect(second.wasCancelled && second.copied == 0)
    }

    @Test
    func errorsCanBeSkippedRetriedOrEndTheRun() {
        let plan = SyncPlan(rows: rows())
        memory.removeTree("/L/new.txt")
        memory.removeTree("/R/back.txt")
        var failed: [String] = []
        var outcome = run(plan) { executor in
            executor.onError = { url, _ in
                failed.append(url.lastPathComponent)
                return .skip
            }
        }
        #expect(
            failed == ["back.txt", "new.txt"] && outcome.errors.count == 2 && outcome.skipped == 2
                && outcome.copied == 2
        )
        #expect(memory.contents("/L/back.txt") == "older" && memory.contents("/R/update.txt") == "newer on the left")

        // Retry after the cause has gone.
        memory.addFile("/R/update.txt", "older", modified: early)
        outcome = run(plan) { executor in
            executor.onError = { url, _ in
                if url.lastPathComponent == "new.txt" { memory.addFile("/L/new.txt", "back again") }
                return url.lastPathComponent == "new.txt" ? .retry : .skip
            }
        }
        #expect(outcome.errors.count == 1 && memory.contents("/R/new.txt") == "back again")

        memory.removeTree("/R/new.txt")
        memory.removeTree("/L/new.txt")
        memory.addFile("/R/update.txt", "older", modified: early)
        outcome = run(plan) { $0.onError = { _, _ in .cancel } }
        #expect(outcome.wasCancelled && memory.contents("/R/update.txt") == "older")
    }

    @Test
    func asymmetricMakesTheRightACopyOfTheLeft() {
        memory.addFile("/R/stale/old.txt", "stale")
        memory.addDirectory("/R/hollow/inner")
        memory.addDirectory("/L/hollow")
        var all = rows {
            $0.asymmetric = true
            $0.emptyDirectories = true
        }
        // The user also sends the left version of the file that is newer on the right.
        for index in all.indices where all[index].name == "back.txt" { all[index].action = .copyToRight }
        let plan = SyncPlan(rows: all)
        #expect(plan.toLeft.isEmpty && plan.deleteRight.count == 6)
        let outcome = run(plan, options: { $0.removeEmptyDirectoriesBelow = memory.url("/R") })
        #expect(outcome.errors.isEmpty && outcome.skipped == 0)
        // "Delete all empty directories" also takes those the left has (spec 09 › dialog).
        #expect(
            memory.allPaths.filter { $0.hasPrefix("/R") } == [
                "/R", "/R/back.txt", "/R/new.txt", "/R/same.txt", "/R/update.txt"
            ]
        )
        #expect(memory.contents("/R/back.txt") == "older")
    }

    @Test
    func foldersAreCreatedAndAFolderTheUserKeptAFileInStays() {
        memory.addDirectory("/L/fresh/inner")
        memory.addFile("/R/doomed/keep.txt")
        memory.addFile("/R/doomed/go.txt")
        var all = rows {
            $0.asymmetric = true
            $0.emptyDirectories = true
        }
        for index in all.indices where all[index].name == "keep.txt" { all[index].action = .none }
        let outcome = run(
            SyncPlan(
                rows: all.filter {
                    $0.directory.hasPrefix("doomed") || $0.name == "doomed" || $0.relativePath.hasPrefix("fresh")
                }
            )
        )
        #expect(
            memory.exists("/R/fresh/inner") && memory.exists("/R/doomed/keep.txt") && !memory.exists("/R/doomed/go.txt")
        )
        #expect(outcome.errors.isEmpty && outcome.skipped == 1 && outcome.deleted == 1 && outcome.copied == 2)
    }

    @Test
    func deletingOnBothSidesAndOnTheLeft() {
        var all = rows()
        for index in all.indices {
            if all[index].name == "same.txt" { all[index].action = .deleteBoth }
            if all[index].name == "new.txt" { all[index].action = .deleteLeft }
            if all[index].name == "update.txt" { all[index].action = .none }
        }
        var outcome = run(
            SyncPlan(rows: all),
            options: {
                $0.deleteLeft = false
                $0.copyToLeft = false
            }
        )
        // Parts of the plan the dialog switched off are not run.
        #expect(
            outcome.deleted == 1 && outcome.copied == 0 && memory.exists("/L/same.txt") && !memory.exists("/R/same.txt")
                && !memory.exists("/L/sub")
        )
        outcome = run(SyncPlan(rows: all.filter { $0.name != "same.txt" }))
        #expect(!memory.exists("/L/new.txt") && memory.exists("/L/sub/deep/arrives.txt") && outcome.deleted == 1)
    }

    @Test
    func anotherTargetFolderKeepsTheRelativePaths() {
        var plan = SyncPlan(rows: rows())
        plan.retarget(toRight: false, root: memory.url("/Elsewhere"))
        plan.retarget(toRight: true, root: memory.url("/Backup/today"))
        run(plan)
        #expect(
            memory.contents("/Elsewhere/sub/deep/arrives.txt") == "from the right"
                && memory.contents("/Backup/today/new.txt") == "from the left"
        )
        #expect(memory.contents("/L/back.txt") == "older" && !memory.exists("/L/sub"))
    }

    @Test
    func worksBetweenDiskAndAnotherFileSystem() throws {
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
        let outcome = run(SyncPlan(rows: compare()))
        #expect(outcome.errors.isEmpty && outcome.copied == 4)
        #expect(
            memory.contents("/M/disk.txt") == "from the disk" && memory.contents("/M/both.txt") == "disk version, newer"
        )
        #expect(memory.contents("/M/nested/deep.txt") == "deep" && box.read("L/mem/only.txt") == "from memory")
        #expect(namesOnDisk(box.url("L")) == ["both.txt", "disk.txt", "mem", "nested"])
        let after = compare()
        #expect(after.count == 4 && after.allSatisfy { $0.state == .equal })
    }

    @Test
    func aFileSystemThatCopiesNothingItselfIsStreamed() {
        memory.refusesInternalCopy = true
        let outcome = run(SyncPlan(rows: rows()))
        #expect(
            outcome.copied == 4 && outcome.errors.isEmpty && memory.contents("/R/update.txt") == "newer on the left"
        )
        #expect(memory.item(at: memory.url("/R/update.txt"))?.modified == early.addingTimeInterval(60))
    }
}
