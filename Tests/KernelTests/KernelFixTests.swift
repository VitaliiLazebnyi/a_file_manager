import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// A fixed sequence of numbers, so a failing case can be found again.
private struct Sequence {
    var state: UInt64
    mutating func next(_ limit: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(limit))
    }
}

private func entry(_ name: String, folder: Bool = false, size: Int64 = 0, time: TimeInterval = 0) -> FileItem {
    FileItem(
        url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: folder, size: size,
        modified: Date(timeIntervalSince1970: time))
}

/// Names of every kind the order has to cope with: case, digits, punctuation, accents written
/// in one or two characters, other scripts, dots in odd places.
private func variedItems(_ count: Int, seed: UInt64) -> [FileItem] {
    var random = Sequence(state: seed)
    let words = [
        "report", "Report", "REPORT", "img_", "IMG-", "read me", "a", "B", "z", "data(1)", "x_y", "résumé",
        "re\u{301}sume\u{301}",
        "Übung", "übung", "uebung", "été", "naïve", "ñandú", "Ångström", "straße", "strasse", "İstanbul", "файл",
        "Файл", "отчёт",
        "写真", "資料", "ｆｕｌｌ", "full", "한국어", "ﬁle", "file", "e\u{301}", "é", "#tag", "~temp", "100", "20", "3"
    ]
    let extensions = ["txt", "TXT", "Txt", "md", "jpg", "JPG", "tar.gz", "", "", "c", "h", "é", "файл", "x."]
    return (0..<count).map { _ in
        var name = words[random.next(words.count)]
        if random.next(3) > 0 { name += String(random.next(max(count / 3, 4))) }
        if random.next(5) == 0 { name = "." + name }
        let folder = random.next(8) == 0
        let ext = extensions[random.next(extensions.count)]
        if !ext.isEmpty, random.next(folder ? 4 : 1) == 0 { name += "." + ext }
        return entry(name, folder: folder, size: Int64(random.next(40)), time: TimeInterval(random.next(60)))
    }
}

private let everyOrder = [SortKey.name, .ext, .size, .date, .unsorted].flatMap {
    [ListOrder(key: $0), ListOrder(key: $0, descending: true)]
}

@Suite struct SortingByKeys {
    /// The order is defined by `areInOrder`; a stable sort with it is what sorting has to give.
    private func reference(_ items: [FileItem], _ order: ListOrder) -> [FileItem] {
        items.sorted { Sorter.areInOrder($0, $1, by: order) }
    }

    @Test func sortingGivesTheOrderOfTheComparisonForEveryKindOfName() {
        for (count, seed) in [(0, 1), (1, 2), (2, 3), (700, 4), (3_000, 5)] as [(Int, UInt64)] {
            let items = variedItems(count, seed: seed)
            for order in everyOrder {
                #expect(Sorter.sort(items, by: order) == reference(items, order), "\(count) items by \(order)")
            }
        }
    }

    @Test func aLongListSortedOnAllCoresComesOutTheSame() {
        // Long enough to be dealt into buckets, with many names that are equal or nearly so.
        let items = variedItems(12_000, seed: 6)
        for order in [
            ListOrder(key: .name), ListOrder(key: .ext, descending: true), ListOrder(key: .size),
            ListOrder(key: .unsorted)
        ] {
            #expect(Sorter.sort(items, by: order).map(\.name) == reference(items, order).map(\.name), "by \(order)")
        }
    }

    @Test func everyLanguageSortsByItsOwnKeysAndNothingElse() {
        // Danish sorts `aa` and the letters with rings and strokes after `z`; Swedish and
        // German each have their own ideas. Whatever the language, the sorted list is the
        // one its comparison of two items defines, and the comparison is an order: the
        // same list comes out however the items were shuffled before.
        var random = Sequence(state: 11)
        let syllables = [
            "aa", "a", "å", "ä", "ae", "æ", "ö", "ø", "o", "z", "y", "ü", "u", "w", "v", "ch", "c", "h", "Aa", "Z",
            "ll", "l", "ñ", "n"
        ]
        let items = (0..<2_500).map { index -> FileItem in
            let name =
                (0..<(1 + random.next(3))).map { _ in syllables[random.next(syllables.count)] }.joined()
                + String(random.next(50)) + "-\(index)"
            return entry(index % 3 == 0 ? name + ".txt" : name, folder: index % 11 == 0, size: Int64(random.next(9)))
        }
        for order in [ListOrder(key: .name), ListOrder(key: .ext, descending: true), ListOrder(key: .size)] {
            for collator in ["da", "sv", "de@collation=phonebook", "es@collation=traditional", "cs"].map(
                NameCollator.init(identifier:)) + [.unavailable]
            {
                let sorted = Sorter.sort(items, by: order, collator: collator)
                #expect(
                    sorted == items.sorted { Sorter.areInOrder($0, $1, by: order, collator: collator) }, "by \(order)"
                )
                #expect(
                    Sorter.sort(items.reversed(), by: order, collator: collator) == sorted, "shuffled, by \(order)")
            }
        }
    }

    @Test func plainNamesAreInTheOrderOfTheComparison() {
        // Printable ASCII is the case the keys decide alone, without a check: every pair of
        // short names made of characters that sort in surprising places, and longer ones.
        let characters = [
            "a", "A", "b", "Z", "0", "9", " ", ".", "-", "_", "~", "!", "(", "[", "{", "'", "+", "=", "@", "#"
        ]
        var names = characters + characters.flatMap { first in characters.map { first + $0 } }
        names += characters.flatMap { first in characters.map { "ab" + first + "c" + $0 + ".x" + first } }
        let items = names.enumerated().map { entry($1, folder: $0 % 7 == 0) }
        for order in [ListOrder(key: .name), ListOrder(key: .ext), ListOrder(key: .name, descending: true)] {
            #expect(Sorter.sort(items, by: order).map(\.name) == reference(items, order).map(\.name), "by \(order)")
        }
    }

    @Test func mergingAndAddingBatchesGiveTheSortedList() {
        let items = variedItems(1_500, seed: 7)
        for order in everyOrder {
            let (first, second) = (Array(items[..<900]), Array(items[900...]))
            let merged = Sorter.merge(Sorter.sort(first, by: order), with: Sorter.sort(second, by: order), by: order)
            #expect(merged == reference(first + second, order), "merge by \(order)")
            var list = SortedFileList(order: order)
            var added: [FileItem] = []
            for start in stride(from: 0, to: items.count, by: 400) {
                let batch = Array(items[start..<min(start + 400, items.count)])
                list.add(batch)
                added += batch
                #expect(list.count == added.count)
            }
            #expect(list.items == reference(items, order), "batches by \(order)")
        }
    }

    @Test func turningTheDirectionRoundGivesWhatSortingGives() {
        // With names that are equal for the order (the same name twice) and without.
        for items in [
            variedItems(800, seed: 8),
            variedItems(800, seed: 9).enumerated().map {
                entry("n\($0)-" + $1.name, folder: $1.isFolder, size: $1.size)
            }
        ] {
            for order in everyOrder {
                let sorted = Sorter.sort(items, by: order)
                let turned = ListOrder(key: order.key, descending: !order.descending)
                #expect(
                    Sorter.resort(sorted, from: order, to: turned) == Sorter.sort(sorted, by: turned),
                    "\(order) turned round")
                let other = ListOrder(key: order.key == .size ? .name : .size)
                #expect(Sorter.resort(sorted, from: order, to: other) == Sorter.sort(sorted, by: other))
            }
        }
    }

    @Test func namesAreCutByTheirBytesAsByTheirCharacters() {
        func slow(_ name: String) -> (String, String) {
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex
            else { return (name, "") }
            return (String(name[..<dot]), String(name[name.index(after: dot)...]))
        }
        let names =
            [
                "a.b", ".a", "a.", "a", "", ".", "..", "a..b", "é.é", "a.\u{301}b", "a.b.\u{301}", "a\u{301}.b",
                "写真.jpg", "x.写真", "\u{600}.a",
                "a.b\u{301}", "…", "a.b c.d", "🇯🇵.🇯🇵", "👨‍👩‍👧.txt"
            ] + variedItems(300, seed: 10).map(\.name)
        for name in names {
            #expect(FileItem.split(name) == slow(name), "\(name.debugDescription)")
        }
    }
}

@Suite struct ParallelWork {
    @Test func nestedMapsGiveTheSameResultsAsPlainLoops() {
        // A tree of calls three levels deep, with uneven branches.
        func walk(_ depth: Int, _ seed: Int) -> Int {
            guard depth > 0 else { return seed }
            return Parallel.map(Array(0..<(2 + seed % 5))) { walk(depth - 1, seed * 7 + $0) }.reduce(seed, &+)
        }
        func plain(_ depth: Int, _ seed: Int) -> Int {
            guard depth > 0 else { return seed }
            return (0..<(2 + seed % 5)).map { plain(depth - 1, seed * 7 + $0) }.reduce(seed, &+)
        }
        #expect(Parallel.map(Array(0..<40)) { walk(4, $0) } == (0..<40).map { plain(4, $0) })
    }

    @Test func workBelowTheTopLevelIsSpreadOverTheCores() {
        // As many outer pieces as cores used to leave the inner calls with one thread each.
        // Here one outer piece holds nearly all the work: its inner pieces must run at once.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        guard cores >= 4 else { return }
        let lock = NSLock()
        var (running, most) = (0, 0)
        // A piece stays until a second one runs beside it (a condition, not a length of time:
        // on a busy machine a helper thread may be long in coming), or for very long if none
        // ever does, which is the failure.
        let deadline = Date().addingTimeInterval(60)
        _ = Parallel.map(Array(0..<cores)) { outer -> Int in
            guard outer == 0 else { return 0 }
            return Parallel.map(Array(0..<(cores * 2))) { _ -> Int in
                lock.lock()
                running += 1
                most = max(most, running)
                lock.unlock()
                while Date() < deadline {
                    lock.lock()
                    let isShared = most > 1
                    lock.unlock()
                    if isShared { break }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                // Long enough for the pieces that run at once to be seen running at once.
                Thread.sleep(forTimeInterval: 0.01)
                lock.lock()
                running -= 1
                lock.unlock()
                return 1
            }.reduce(0, +)
        }
        #expect(most > 1)
        // Sleeping pieces count as waiting, which earns a job more threads, up to a limit.
        #expect(most <= cores * 4)
    }

    @Test func aJobIsNotLeftAloneWhileEveryThreadWaitsForSomething() {
        // Pieces that wait, like pieces that wait for a server, take up every helper thread.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let gate = NSCondition()
        var (isOpen, waiting) = (false, 0)
        let sleepers = DispatchGroup()
        sleepers.enter()
        Thread {
            _ = Parallel.map(Array(0..<(cores * 2))) { _ in
                gate.lock()
                waiting += 1
                gate.broadcast()
                // Let go by the test; never held for longer than a hang would be.
                let end = Date().addingTimeInterval(120)
                while !isOpen, gate.wait(until: end) {}
                gate.unlock()
            }
            sleepers.leave()
        }.start()
        // Until the waiting job holds threads: a condition, not a length of time.
        gate.lock()
        let end = Date().addingTimeInterval(60)
        while waiting < min(2, cores), gate.wait(until: end) {}
        gate.unlock()
        let lock = NSLock()
        var (running, most) = (0, 0)
        let deadline = Date().addingTimeInterval(60)
        _ = Parallel.map(Array(0..<8)) { _ in
            lock.lock()
            running += 1
            most = max(most, running)
            lock.unlock()
            // Stays until a second piece runs beside it, however long a thread takes to come.
            while Date() < deadline {
                lock.lock()
                let isShared = most > 1
                lock.unlock()
                if isShared || cores == 1 { break }
                Thread.sleep(forTimeInterval: 0.002)
            }
            lock.lock()
            running -= 1
            lock.unlock()
        }
        #expect(most > 1 || cores == 1)
        gate.lock()
        isOpen = true
        gate.broadcast()
        gate.unlock()
        sleepers.wait()
    }

    @Test func manyCallersAtOnceAllFinish() {
        let results = DispatchQueue.global().sync { () -> [Int] in
            var sums = [Int](repeating: 0, count: 24)
            sums.withUnsafeMutableBufferPointer { sums in
                let slots = sums.baseAddress!
                DispatchQueue.concurrentPerform(iterations: 24) { caller in
                    slots[caller] = Parallel.map(Array(0..<200)) {
                        Parallel.map([$0, caller]) { $0 * 2 }.reduce(0, +)
                    }.reduce(0, +)
                }
            }
            return sums
        }
        #expect(results == (0..<24).map { caller in (0..<200).reduce(0) { $0 + ($1 + caller) * 2 } })
    }
}

@MainActor @Suite struct PanelModelFixes {
    private let directory = URL(fileURLWithPath: "/work", isDirectory: true)

    private func model(_ items: [FileItem], sort: ListOrder = ListOrder()) -> PanelModel {
        let model = PanelModel(directory: directory, sort: sort)
        model.show(listing(items))
        return model
    }

    private func listing(_ items: [FileItem]) -> Listing {
        Listing(
            directory: directory, items: items, parent: URL(fileURLWithPath: "/", isDirectory: true),
            root: URL(fileURLWithPath: "/", isDirectory: true))
    }

    /// The totals as they are defined, counted from scratch.
    private func counted(_ model: PanelModel) -> PanelModel.Totals {
        var totals = PanelModel.Totals()
        for item in model.items {
            let size = item.isFolder ? (item.computedSize ?? 0) : item.size
            let selected = model.selection.contains(item.name)
            totals.totalBytes += size
            if item.isFolder { totals.totalFolders += 1 } else { totals.totalFiles += 1 }
            guard selected else { continue }
            totals.selectedBytes += size
            if item.isFolder { totals.selectedFolders += 1 } else { totals.selectedFiles += 1 }
        }
        return totals
    }

    private var sample: [FileItem] {
        (0..<300).map { number -> FileItem in
            let isFolder = number % 10 == 0
            return entry(isFolder ? "folder\(number)" : "file\(number).txt", folder: isFolder, size: Int64(number * 3))
        }
    }

    @Test func rowsAreFoundByNameHoweverOftenTheyAreAsked() {
        let model = model(sample)
        for _ in 0..<3 {
            for (index, item) in model.items.enumerated() { #expect(model.row(ofName: item.name) == index + 1) }
            #expect(model.row(ofName: "missing") == nil)
        }
        // The index of names follows the list.
        model.setSort(ListOrder(key: .size, descending: true))
        for (index, item) in model.items.enumerated() { #expect(model.row(ofName: item.name) == index + 1) }
        model.setFilter(.mask("*7.txt"))
        #expect(model.row(ofName: "file7.txt") != nil && model.row(ofName: "file8.txt") == nil)
        for (index, item) in model.items.enumerated() { #expect(model.row(ofName: item.name) == index + 1) }
    }

    @Test func theTotalsStayRightThroughEveryChange() {
        let model = model(sample)
        #expect(model.totals == counted(model))
        model.toggleSelection(row: 5)
        model.toggleSelection(row: 1)
        #expect(model.totals == counted(model) && model.totals.selectedFolders == 2)
        model.toggleSelection(row: 5)
        model.setSelected(true, rows: 10...40)
        model.setSelected(false, rows: 20...25)
        model.setSelected(true, rows: 0...3)
        #expect(model.totals == counted(model))
        model.setSelected(true, names: ["file7.txt", "folder0", "missing", "file7.txt"])
        #expect(model.selection.contains("file7.txt") && !model.selection.contains("missing"))
        #expect(model.totals == counted(model))
        model.setSelected(false, names: ["file7.txt", "file12.txt"])
        #expect(model.totals == counted(model))
        model.setComputedSize(5_000, forName: "folder0")
        #expect(model.totals == counted(model) && model.totals.selectedBytes >= 5_000)
        model.setComputedSize(70, forName: "folder0")
        model.setComputedSize(9, forName: "folder10")
        #expect(model.totals == counted(model))
        model.setComputedSizes(["folder20": 11, "folder30": 12, "missing": 13])
        #expect(model.totals == counted(model))
        #expect(
            model.items.first { $0.name == "folder30" }?.computedSize == 12
                && model.listedItems.first { $0.name == "folder20" }?.computedSize == 11)
        model.invertSelection()
        #expect(model.totals == counted(model))
        model.deselect(["file1.txt", "file2.txt"])
        #expect(model.totals == counted(model))
        model.setFilter(.mask("*1.txt"))
        #expect(model.totals == counted(model))
        model.setComputedSize(8, forName: "folder40")
        #expect(model.totals == counted(model) && model.listedItems.first { $0.name == "folder40" }?.computedSize == 8)
        model.setFilter(nil)
        model.selectAll()
        model.update(with: listing(Array(sample.dropFirst(7))))
        #expect(model.totals == counted(model))
        #expect(model.items.first { $0.name == "folder20" }?.computedSize == 11)
    }

    @Test func batchChangesAreAnnouncedOnce() {
        let model = model(sample)
        var changes = 0
        model.onChange = { _ in changes += 1 }
        model.setComputedSizes(["folder0": 1, "folder10": 2, "folder20": 3])
        #expect(changes == 1)
        model.setSelected(true, names: ["file1.txt", "file2.txt", "file3.txt"])
        #expect(changes == 2 && model.selection.count == 3)
        model.setComputedSizes(["missing": 1])
        model.setComputedSizes([:])
        #expect(changes == 2)
    }

    @Test func theSelectionIsReplacedInOneAnnouncement() {
        let model = model(sample)
        model.setSelected(true, names: ["file1.txt", "file2.txt"])
        var changes = 0
        model.onChange = { _ in changes += 1 }
        model.setSelection(names: ["file2.txt", "file3.txt", "missing"])
        #expect(changes == 1 && model.selection == ["file2.txt", "file3.txt"])
        #expect(model.totals == counted(model))
        model.setSelection(names: [] as [String])
        #expect(changes == 2 && model.selection.isEmpty)
    }

    @Test func operandsThatIncludeAFileAreFoundWithoutTheList() {
        let model = model(sample)
        // Without marks the cursor decides: on [..] and on a folder there is no file.
        model.moveCursor(to: 0)
        #expect(!model.hasOperandFile)
        model.moveCursor(to: model.row(ofName: "folder0")!)
        #expect(!model.hasOperandFile)
        model.moveCursor(to: model.row(ofName: "file1.txt")!)
        #expect(model.hasOperandFile)
        // With marks, the marks do: only folders marked is no file even with the cursor on one.
        model.setSelected(true, names: ["folder0", "folder10"])
        #expect(!model.hasOperandFile)
        model.setSelected(true, names: ["file7.txt"])
        #expect(model.hasOperandFile)
    }

    @Test func aNarrowingFilterGivesWhatTheFullFilterGives() {
        let wide = PanelFilter(title: "wide") { $0.isFolder || $0.name.contains("1") }
        let narrow = PanelFilter(title: "narrow") { $0.isFolder || $0.name.contains("12") }
        let narrowed = model(sample)
        let whole = model(sample)
        narrowed.setSelected(true, names: ["file12.txt", "file120.txt", "file5.txt"])
        whole.setSelected(true, names: ["file12.txt", "file120.txt", "file5.txt"])
        narrowed.setFilter(wide)
        narrowed.moveCursor(to: narrowed.row(ofName: "file12.txt")!)
        let version = narrowed.listVersion
        narrowed.setFilter(narrow, narrowing: true)
        whole.setFilter(narrow)
        // A filter shows less of the list; the list itself is what it was.
        #expect(narrowed.listVersion == version)
        #expect(narrowed.items.map(\.name) == whole.items.map(\.name) && narrowed.listedItems.count == 300)
        #expect(
            narrowed.selection == whole.selection && narrowed.cursorItem?.name == "file12.txt"
                && narrowed.totals == counted(narrowed))
        // Taking the filter off shows everything again.
        narrowed.setFilter(nil)
        #expect(narrowed.items.count == 300)
    }

    @Test func rawDataIsStoredAsItIs() {
        let settings = MemorySettings()
        let data = Data([1, 2, 3])
        settings.set(data, forKey: "raw")
        #expect(settings.data(forKey: "raw") == data)
        settings.set(["a"], forKey: "list")
        #expect(settings.value([String].self, forKey: "list") == ["a"])
    }

    @Test func sumsThatLeaveTheRangeOfANumberStopAtItsEnd() {
        let huge = [
            entry("a.bin", size: .max - 10), entry("b.bin", size: .max - 10), entry("c.bin", size: 100),
            entry("d", folder: true)
        ]
        let model = model(huge)
        #expect(model.totals.totalBytes == .max)
        model.selectAll()
        #expect(model.totals.selectedBytes == .max)
        model.toggleSelection(row: model.row(ofName: "a.bin")!)
        model.toggleSelection(row: model.row(ofName: "b.bin")!)
        #expect(model.totals.selectedBytes == 100)
        model.toggleSelection(row: model.row(ofName: "a.bin")!)
        model.toggleSelection(row: model.row(ofName: "b.bin")!)
        #expect(model.totals.selectedBytes == .max)
        model.setComputedSize(.max, forName: "d")
        #expect(model.totals.selectedBytes == .max && model.totals.totalBytes == .max)
        #expect(
            Int64.max.addingSaturated(1) == .max && Int64.min.addingSaturated(-1) == .min
                && Int64(2).addingSaturated(3) == 5)

        let memory = MemoryFileSystem()
        memory.addFile("/big/a/one.bin", "x")
        memory.addFile("/big/b/two.bin", "x")
        let inflated = HugeSizes(memory)
        #expect(inflated.totalSize(of: memory.url("/big")) == .max)
    }

    @Test func aPresortedListIsTakenAsItIs() {
        let model = model(sample)
        model.moveCursor(to: model.row(ofName: "file7.txt")!)
        let order = ListOrder(key: .size, descending: true)
        let version = model.listVersion
        let sorted = Sorter.resort(model.listedItems, from: model.sort, to: order)
        #expect(model.listVersion == version)
        model.setSort(order, presorted: sorted)
        #expect(
            model.sort == order && model.items == Sorter.sort(sample, by: order)
                && model.cursorItem?.name == "file7.txt")
        #expect(model.listVersion != version)
        // A list of another length cannot be this list in another order.
        model.setSort(ListOrder(key: .name), presorted: Array(sorted.dropLast()))
        #expect(model.items == Sorter.sort(sample, by: ListOrder(key: .name)))
        // Turning the direction round is the same as sorting.
        model.setSort(ListOrder(key: .name, descending: true))
        #expect(model.items == Sorter.sort(sample, by: ListOrder(key: .name, descending: true)))
    }

    @Test func aRefreshThatOnlyEndsTheWaitingIsAnnounced() {
        let model = PanelModel(directory: directory)
        model.showRemembered(listing(sample))
        #expect(model.isRefreshing && !model.isComplete)
        var changes = 0
        model.onChange = { _ in changes += 1 }
        // The fresh reading holds what was shown: nothing in the list changes, the state does.
        #expect(model.update(with: listing(sample)))
        #expect(changes == 1 && !model.isRefreshing && model.isComplete)
        #expect(!model.update(with: listing(sample)))
        #expect(changes == 1)
    }

    @Test func aLongListThatDidNotChangeIsSeenAsTheSame() {
        let long = (0..<70_000).map { entry("file\($0).txt", size: Int64($0)) }
        let sorted = Sorter.sort(long, by: ListOrder())
        let model = PanelModel(directory: directory)
        model.show(listing(sorted), presorted: ListOrder())
        model.moveCursor(to: 40_000)
        #expect(!model.update(with: listing(sorted), presorted: ListOrder()))
        #expect(model.cursor == 40_000)
        var changed = sorted
        changed[69_000] = entry(changed[69_000].name, size: 1)
        #expect(model.update(with: listing(changed), presorted: ListOrder()))
        #expect(model.cursor == 40_000 && model.items[69_000].size == 1)
    }
}

/// A file system that claims impossible sizes, as a crafted archive can.
private final class HugeSizes: FileSystemProvider {
    let inner: MemoryFileSystem
    init(_ inner: MemoryFileSystem) { self.inner = inner }

    var scheme: String { inner.scheme }
    var capabilities: FileSystemCapabilities { inner.capabilities }
    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try inner.list(directory, showHidden: showHidden).map {
            FileItem(url: $0.url, name: $0.name, isDirectory: $0.isDirectory, size: $0.isDirectory ? 0 : .max - 5)
        }
    }
    func item(at url: URL) -> FileItem? { inner.item(at: url) }
    func parent(of directory: URL) -> URL? { inner.parent(of: directory) }
    func read(_ url: URL) throws -> FileReader { try inner.read(url) }
    func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }
    func write(_ url: URL) throws -> FileWriter { try inner.write(url) }
    func remove(_ url: URL) throws { try inner.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try inner.move(source, to: destination, replacing: replacing)
    }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try inner.copy(source, to: destination, progress: progress)
    }
}

@Suite struct FileMaskFixes {
    /// The matching spelled out the slow way: both without case and with composed accents,
    /// then character by character (as Unicode numbers them), `*` for any run and `?` for one.
    private func reference(_ text: String, _ name: String) -> Bool {
        func fold(_ text: String) -> String {
            text.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
        }
        func fits(_ pattern: ArraySlice<Unicode.Scalar>, _ name: ArraySlice<Unicode.Scalar>) -> Bool {
            guard let first = pattern.first else { return name.isEmpty }
            if first == "*" {
                return (name.startIndex...name.endIndex).contains { fits(pattern.dropFirst(), name[$0...]) }
            }
            guard let character = name.first, first == "?" || first == character else { return false }
            return fits(pattern.dropFirst(), name.dropFirst())
        }
        let patterns = fold(text).split(whereSeparator: { $0 == " " || $0 == ";" }).map(String.init)
        let name = fold(name)
        return patterns.contains { pattern in
            if pattern == "*.*" || pattern == "*" { return true }
            let wanted = pattern.hasSuffix(".") && !name.utf8.contains(0x2E) ? String(pattern.dropLast()) : pattern
            return fits(ArraySlice(Array(wanted.unicodeScalars)), ArraySlice(Array(name.unicodeScalars)))
        }
    }

    @Test func aMaskReadOnceMatchesLikeTheMaskReadEveryTime() {
        let masks = [
            "*.txt", "*.TXT", "*", "*.*", "", "*.", "name.", "*report*", "*Re*", "report_??.*", "[a-c]*.md", "*.t?t",
            "a*b*c", "*é*", "*.É",
            "файл*", "*ФАЙЛ*", "*.txt;*.md", "*.txt  *.jpg", "**", "*a.b*", "?", "\\*", "*[*", "x", "*.", "*x.", "*写真*",
            "*.tar.gz", "*ı*", "*k*", "k*", "*σ", "*ς", "*.", "*ss*", "*日本*", "ünï*"
        ]
        let names = [
            "report.txt", "REPORT.TXT", "Report_01.Txt", "a.md", "B.MD", "d.md", "name", "NAME", "name.x", "abc",
            "aXbYc", "été.É", "ÉTÉ.é",
            "файл.txt", "ФАЙЛ", "мой файл", "x", "", ".", "a.b", "*", "[", "写真.jpg", "archive.TAR.GZ", "İstanbul",
            "ISTANBUL", "a.b\u{301}", "no ext",
            "\u{212A}elvin.txt", "ΟΔΟΣ.md", "οδος", "straße.TXT", "STRASSE", "ǅ.txt", "名前.", "日本語.TXT", "x.\u{301}",
            "файл", "Ünïcödé.Md"
        ]
        for mask in masks {
            let compiled = FileMask(mask)
            for name in names {
                #expect(
                    compiled.matches(name) == reference(mask, name),
                    "\(mask.debugDescription) on \(name.debugDescription)")
            }
        }
    }
}
