@testable import AFMKernel
import Foundation
import TestSupport
import Testing

// Review round 2, integration: what the kernel gained when the round was closed — entering a
// folder through `prepare`/`apply` (shell-p2 request 2), and the comparison of names that
// plugins use in place of Foundation's localized ones (K001 outside the panels' sorter).

private let home = URL(fileURLWithPath: "/review2/integration/home")
private let other = URL(fileURLWithPath: "/review2/integration/other")

private func entry(_ name: String, in folder: URL, size: Int64 = 1, folder isFolder: Bool = false) -> FileItem {
    FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: isFolder, size: size)
}

private func listing(_ folder: URL, _ items: [FileItem]) -> Listing {
    Listing(directory: folder, items: items, parent: folder.deletingLastPathComponent(), root: URL(fileURLWithPath: "/"))
}

private func elsewhere<Value>(_ work: @escaping () -> Value) -> Value {
    let done = DispatchSemaphore(value: 0)
    var value: Value?
    Thread.detachNewThread {
        value = work()
        done.signal()
    }
    done.wait()
    return value!
}

@MainActor @Suite struct Review2IntegrationEntering {
    private func model() -> PanelModel {
        let model = PanelModel(directory: home, sort: ListOrder(key: .name))
        model.show(listing(home, [entry("b.txt", in: home), entry("a.txt", in: home)]))
        return model
    }

    private var arrival: [FileItem] {
        [entry("zeta.txt", in: other, size: 3), entry("Docs", in: other, folder: true), entry("alpha.log", in: other, size: 5),
         entry("mid.txt", in: other, size: 7)]
    }

    @Test func aFolderEnteredThroughPrepareIsTheFolderShowWouldHaveEntered() {
        let direct = model()
        direct.show(listing(other, arrival), focus: "mid.txt")
        let prepared = model()
        let basis = prepared.basis
        let change = elsewhere { PanelModel.prepare(basis, show: listing(other, self.arrival), focus: "mid.txt") }
        #expect(prepared.apply(change) == .changed)
        #expect(prepared.directory == direct.directory && prepared.items.map(\.name) == direct.items.map(\.name))
        #expect(prepared.items.map(\.name) == ["Docs", "alpha.log", "mid.txt", "zeta.txt"])
        #expect(prepared.cursorItem?.name == "mid.txt" && prepared.cursor == direct.cursor)
        #expect(prepared.isComplete && prepared.isListed && !prepared.isRefreshing && !prepared.hasSelection)
        #expect(prepared.totals.totalFiles == direct.totals.totalFiles && prepared.totals.totalBytes == 15)
        // The visit is in the history, as after `show`.
        #expect(prepared.backLocation == direct.backLocation && prepared.backLocation?.path == home.path)
    }

    @Test func theFilterTheOrderThatWasAskedForAndARememberedListingAreTakenAsShowTakesThem() {
        let model = model()
        model.setFilter(.mask("*.txt"))
        // An order the user asked for and the list is not in yet.
        model.requestSort(ListOrder(key: .size, descending: true))
        let basis = model.basis
        let change = elsewhere { PanelModel.prepare(basis, show: listing(other, self.arrival), history: .keep, remembered: true) }
        #expect(model.apply(change) == .changed)
        // Filtered (folders stay), in the order that was asked for, which is the panel's now.
        #expect(model.items.map(\.name) == ["Docs", "mid.txt", "zeta.txt"])
        #expect(model.sort == ListOrder(key: .size, descending: true) && model.requestedSort == nil)
        // A remembered listing: usable, and not complete until the fresh reading has come.
        #expect(model.isRefreshing && !model.isComplete && model.isListed)
        #expect(model.backLocation == nil)
        #expect(model.update(with: listing(other, arrival + [entry("new.txt", in: other, size: 9)])))
        #expect(model.isComplete && !model.isRefreshing && model.items.map(\.name) == ["Docs", "new.txt", "mid.txt", "zeta.txt"])
    }

    @Test func aPanelThatChangedMeanwhileRefusesTheEnteringAndTakesTheNextOne() {
        let model = model()
        let stale = PanelModel.prepare(model.basis, show: listing(other, arrival))
        // Another filter since the basis was taken: what was prepared shows the wrong entries.
        model.setFilter(.mask("*.log"))
        #expect(model.apply(stale) == .stale && model.directory.path == home.path)
        #expect(model.apply(PanelModel.prepare(model.basis, show: listing(other, arrival))) == .changed)
        #expect(model.items.map(\.name) == ["Docs", "alpha.log"])
    }

    @Test func aLongListIsEnteredWithItsIndexOfNamesMadeInTheBackground() {
        let model = model()
        let many = (0..<30_000).map { entry("file-\($0).dat", in: other, size: Int64($0 % 11)) }
        let basis = model.basis
        let change = elsewhere { PanelModel.prepare(basis, show: listing(other, many), focus: "file-29999.dat") }
        #expect(model.apply(change) == .changed)
        #expect(model.items.count == 30_000 && model.cursorItem?.name == "file-29999.dat")
        #expect(model.row(ofName: "file-12345.dat").flatMap(model.item(atRow:))?.name == "file-12345.dat")
        #expect(model.totals.totalFiles == 30_000)
    }
}

@Suite struct Review2IntegrationNameOrder {
    /// The pair of names Foundation's localized comparison ends the program for (K001,
    /// `Tests/Fuzz/repro/misc/sorter-cfcompare-abort.bin`).
    private var fatalPair: (String, String) {
        (String(repeating: "\u{15}", count: 128) + "\u{FFFD}a" + String(repeating: "0", count: 66), "\u{FFFD}")
    }

    @Test func theNamesFoundationsComparisonDiesOfAreComparedLikeAnyOthers() {
        let (first, second) = fatalPair
        for numeric in [false, true] {
            let forward = Sorter.compare(first, second, numeric: numeric)
            let backward = Sorter.compare(second, first, numeric: numeric)
            #expect(forward != .orderedSame && forward.rawValue == -backward.rawValue)
            #expect(Sorter.compare(first, first, numeric: numeric) == .orderedSame)
            let sorted = Sorter.sorted([first, second, "plain", second, first], numeric: numeric) { $0 }
            #expect(sorted.count == 5 && Sorter.sorted(sorted.reversed(), numeric: numeric) { $0 } == sorted)
        }
    }

    @Test func theOrderIsOneInTheStrictSenseWhereTheLocalizedOneIsNot() {
        // Letters for which the localized comparison says "descending" in both directions (K023).
        let names = ["й", "ий", "и", "е", "ё", "ž", "z", "ñ", "n", "å", "a", "aa", "Й", "ИЙ", "A", "Z", "file2", "file10", "File1"]
        for numeric in [false, true] {
            for a in names {
                for b in names {
                    let (forward, backward) = (Sorter.compare(a, b, numeric: numeric), Sorter.compare(b, a, numeric: numeric))
                    #expect(forward.rawValue == -backward.rawValue, "\(a) \(b)")
                    #expect((forward == .orderedSame) == (a == b), "\(a) \(b)")
                    // The keys say what the comparison says.
                    let (x, y) = (Sorter.key(of: a, numeric: numeric), Sorter.key(of: b, numeric: numeric))
                    #expect((x < y) == (forward == .orderedAscending) && (x == y) == (forward == .orderedSame), "\(a) \(b)")
                    for c in names where forward == .orderedAscending && Sorter.compare(b, c, numeric: numeric) == .orderedAscending {
                        #expect(Sorter.compare(a, c, numeric: numeric) == .orderedAscending, "\(a) \(b) \(c)")
                    }
                }
            }
        }
    }

    @Test func digitsCountByTheirValueOnlyWhenThatIsAskedFor() {
        let names = ["file10.txt", "file2.txt", "File1.txt", "file1000000000000000000000.txt", "file9.txt"]
        #expect(Sorter.sorted(names, numeric: true) { $0 } == ["File1.txt", "file2.txt", "file9.txt", "file10.txt", "file1000000000000000000000.txt"])
        // As the panels' lists have names: character by character.
        #expect(Sorter.sorted(names) { $0 } == ["File1.txt", "file10.txt", "file1000000000000000000000.txt", "file2.txt", "file9.txt"])
        // Items of one name keep the order they came in.
        let pairs = [("b", 1), ("a", 2), ("b", 3), ("a", 4)]
        #expect(Sorter.sorted(pairs) { $0.0 }.map(\.1) == [2, 4, 1, 3])
    }
}

/// The clock for limits on work (`ThreadTime`): what the regular expressions of Find Files,
/// Selection and Multi-Rename are bounded by. Their limits were measured by the clock, and a
/// search then gave up on a text it would have matched whenever the machine kept its thread
/// waiting (seen as `aLongLineIsCutBetweenCharacters` failing in a run under the thread sanitizer).
@Suite struct Review2IntegrationThreadTime {
    @Test func waitingCostsNoneOfAThreadsTimeAndWorkDoes() {
        let before = ThreadTime.used
        Thread.sleep(forTimeInterval: 0.4)
        let afterWaiting = ThreadTime.used
        // Asleep for 0.4 s, the thread has used next to nothing: a limit of a quarter of a second is not spent.
        #expect(afterWaiting >= before && afterWaiting - before < 0.2)
        var sum = 0.0
        // Work until a tenth of a second of the thread's own time has gone, however long that takes by the clock.
        while ThreadTime.used - afterWaiting < 0.1 { for value in 0..<10_000 { sum += Double(value).squareRoot() } }
        #expect(ThreadTime.used - afterWaiting >= 0.1 && sum > 0)
    }

    @Test func eachThreadHasItsOwn() {
        let done = DispatchSemaphore(value: 0)
        var other = 0.0
        Thread.detachNewThread {
            var sum = 0.0
            let start = ThreadTime.used
            while ThreadTime.used - start < 0.1 { for value in 0..<10_000 { sum += Double(value).squareRoot() } }
            other = ThreadTime.used - start + (sum > 0 ? 0 : 1)
            done.signal()
        }
        let mine = ThreadTime.used
        done.wait()
        // The other thread used a tenth of a second; this one waited and used none of it.
        #expect(other >= 0.1 && ThreadTime.used - mine < 0.09)
    }
}
