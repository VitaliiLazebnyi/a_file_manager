import Foundation
import Testing

@testable import AFMKernel

private let folder = URL(fileURLWithPath: "/review2/folder")

private func file(_ name: String, size: Int64 = 1, in directory: URL = folder) -> FileItem {
    FileItem(url: directory.appendingPathComponent(name), name: name, isDirectory: false, size: size)
}

private func dir(_ name: String) -> FileItem {
    FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: true)
}

private func listing(_ items: [FileItem], at directory: URL = folder) -> Listing {
    Listing(
        directory: directory, items: items, parent: directory.deletingLastPathComponent(),
        root: URL(fileURLWithPath: "/"))
}

/// Folders `dir0…`, files `file0.txt…` with sizes that tell them apart.
private func sample(_ count: Int) -> [FileItem] {
    (0..<count).map {
        $0 % 10 == 0 ? dir("dir\($0)") : file("file\($0).\($0 % 3 == 0 ? "txt" : "md")", size: Int64($0 % 97 + 1))
    }
}

@MainActor private func panel(_ items: [FileItem], sort: ListOrder = ListOrder()) -> PanelModel {
    let model = PanelModel(directory: folder, sort: sort)
    model.show(listing(items))
    return model
}

/// The totals counted the plain way, from what the model shows.
@MainActor private func counted(_ model: PanelModel) -> PanelModel.Totals {
    var totals = PanelModel.Totals()
    for (index, item) in model.items.enumerated() {
        let size = item.isFolder ? (item.computedSize ?? 0) : item.size
        totals.totalBytes += size
        if item.isFolder { totals.totalFolders += 1 } else { totals.totalFiles += 1 }
        if model.isSelected(row: index + (model.hasParentRow ? 1 : 0)) {
            totals.selectedBytes += size
            if item.isFolder { totals.selectedFolders += 1 } else { totals.selectedFiles += 1 }
        }
    }
    return totals
}

/// Everything a panel shows, to compare two models by.
@MainActor private func state(_ model: PanelModel) -> [String] {
    [
        model.items.map(\.name).joined(separator: "|"), model.listedItems.map(\.name).joined(separator: "|"),
        model.selectedNames.joined(separator: "|"), "\(model.cursor)", model.cursorItem?.name ?? "-", "\(model.totals)",
        model.filter?.title ?? "-", "\(model.sort)",
        model.items.map { "\($0.computedSize ?? -1)" }.joined(separator: ","),
        model.listedItems.map { "\($0.computedSize ?? -1)" }.joined(separator: ",")
    ]
}

/// Runs work on another thread and waits for it, as a panel does with long lists.
private func elsewhere<Value>(_ work: @escaping @Sendable () -> Value) -> Value {
    let done = DispatchSemaphore(value: 0)
    // Written by the other thread before it signals, read here after the wait.
    nonisolated(unsafe) var value: Value?
    Thread.detachNewThread {
        value = work()
        done.signal()
    }
    done.wait()
    return value!
}

/// Review 2, K010-K020, K030, K033, K041-K046: the panel model.
@MainActor @Suite struct Review2KernelModel {
    // MARK: The version of the list

    @Test func onlyAChangedListMovesTheVersion() {
        let items = sample(300)
        let model = panel(items)
        let version = model.listVersion
        var announced = 0
        model.onChange = { _ in announced += 1 }
        // A refresh that found the directory as it was.
        #expect(!model.update(with: listing(items.reversed())))
        #expect(model.listVersion == version && announced == 0)
        // Calculated sizes, filters, marks.
        model.setComputedSizes([(name: "dir0", size: 500), (name: "dir10", size: 7)])
        model.setFilter(PanelFilter.mask("*.txt"))
        _ = model.setFilter(
            PanelFilter.mask("*.md"), prefiltered: PanelModel.filtered(model.listedItems, by: .mask("*.md")),
            listVersion: version)
        model.setFilter(nil)
        model.selectAll()
        #expect(model.listVersion == version)
        // The same refresh again, now that folders have sizes: still nothing new.
        #expect(!model.update(with: listing(items)))
        #expect(model.listVersion == version && model.item(atRow: model.row(ofName: "dir0")!)?.computedSize == 500)
        // Another order and another reading are other lists.
        model.setSort(ListOrder(key: .size))
        #expect(model.listVersion == version + 1)
        #expect(model.update(with: listing(Array(items.dropLast()))))
        #expect(model.listVersion == version + 2)
    }

    // MARK: Prepared changes

    @Test(arguments: [200, 50_000]) func aPreparedChangeIsWhatTheDirectCallDoes(count: Int) {
        let items = sample(count)
        let filter = PanelFilter(title: "3") { $0.isFolder || $0.name.contains("3") }
        func prepared() -> PanelModel {
            let model = panel(items)
            model.setFilter(PanelFilter(title: "no 7") { !$0.name.contains("7") })
            model.setSelected(true, names: ["file3.txt", "file5.md", "dir10", "file13.md", "file33.txt"])
            model.setComputedSizes([(name: "dir10", size: 1_000), (name: "dir70", size: 70)])
            model.saveSelection()
            model.moveCursor(to: model.row(ofName: "file23.md")!)
            return model
        }
        let fresh = listing(Array(items.dropFirst(4)) + [file("new3.txt", size: 9), dir("newdir")])
        let grown = Sorter.sort(items + [file("zz3.txt"), file("aa.md")], by: ListOrder(key: .ext))
        let changes: [(String, (PanelModel) -> Void, (PanelModel.Basis) -> PanelModel.Prepared)] = [
            (
                "sort", { $0.setSort(ListOrder(key: .size, descending: true)) },
                { PanelModel.prepare($0, sort: ListOrder(key: .size, descending: true)) }
            ),
            (
                "turn", { $0.setSort(ListOrder(key: .name, descending: true)) },
                { PanelModel.prepare($0, sort: ListOrder(key: .name, descending: true)) }
            ),
            ("filter", { $0.setFilter(filter) }, { PanelModel.prepare($0, filter: filter) }),
            ("no filter", { $0.setFilter(nil) }, { PanelModel.prepare($0, filter: nil) }),
            ("update", { $0.update(with: fresh) }, { PanelModel.prepare($0, update: fresh) }),
            (
                "extend", { $0.extend(to: grown, sortedBy: ListOrder(key: .ext)) },
                { PanelModel.prepare($0, extendingTo: grown, sortedBy: ListOrder(key: .ext)) }
            )
        ]
        for (name, direct, prepare) in changes {
            let (one, two) = (prepared(), prepared())
            direct(one)
            var announced = 0
            two.onChange = { if $0 == .contents { announced += 1 } }
            let basis = two.basis
            // Marks, the cursor and sizes that change while the work is under way are kept.
            let made = elsewhere { prepare(basis) }
            #expect(two.apply(made) == .changed, "\(name)")
            #expect(announced == 1, "\(name)")
            #expect(state(one) == state(two), "\(name)")
            #expect(two.totals == counted(two), "\(name)")
            one.restoreSelection()
            two.restoreSelection()
            #expect(state(one) == state(two), "\(name), saved marks")
        }
    }

    @Test func aPreparedChangeOfAModelThatMovedOnIsNotTaken() {
        let items = sample(400)
        let model = panel(items)
        let stale = [
            PanelModel.prepare(model.basis, sort: ListOrder(key: .size)),
            PanelModel.prepare(model.basis, filter: .mask("*.txt")),
            PanelModel.prepare(model.basis, update: listing(Array(items.dropFirst())))
        ]
        let rows = PanelModel.rows(of: model.basis) { $0.name.hasSuffix("txt") }
        model.setSort(ListOrder(key: .ext))
        let before = state(model)
        var announced = 0
        model.onChange = { _ in announced += 1 }
        for prepared in stale { #expect(model.apply(prepared) == .stale) }
        #expect(!model.setSelection(rows))
        #expect(
            !model.setSort(
                ListOrder(), presorted: Sorter.sort(items, by: ListOrder()), listVersion: model.listVersion - 1))
        #expect(state(model) == before && announced == 0)
        // What only touches marks, the cursor or sizes does not make a prepared change stale.
        let basis = model.basis
        let prepared = PanelModel.prepare(basis, sort: ListOrder(key: .name, descending: true))
        model.setSelected(true, names: ["file7.md", "file8.md"])
        model.setComputedSizes([(name: "dir20", size: 20), (name: "dir30", size: 30)])
        model.moveCursor(to: model.row(ofName: "file8.md")!)
        #expect(model.apply(prepared) == .changed)
        #expect(model.selectedNames.sorted() == ["file7.md", "file8.md"] && model.cursorItem?.name == "file8.md")
        #expect(
            model.item(atRow: model.row(ofName: "dir20")!)?.computedSize == 20
                && model.listedItems.first { $0.name == "dir30" }?.computedSize == 30)
        #expect(model.totals == counted(model) && model.totals.totalBytes == counted(model).totalBytes)
    }

    @Test func aRefreshThatFoundNothingNewIsAppliedAsUnchanged() {
        let items = sample(300)
        let model = panel(items)
        model.setSelected(true, names: ["file1.md"])
        var announced = 0
        model.onChange = { _ in announced += 1 }
        let version = model.listVersion
        #expect(model.apply(PanelModel.prepare(model.basis, update: listing(items))) == .unchanged)
        #expect(announced == 0 && model.listVersion == version && model.selectionCount == 1)
        // Another directory is shown, as `update` does it.
        let other = URL(fileURLWithPath: "/review2/other")
        #expect(
            model.apply(PanelModel.prepare(model.basis, update: listing([file("x.txt", in: other)], at: other)))
                == .changed)
        #expect(model.directory.path == other.path && model.items.map(\.name) == ["x.txt"] && model.selectionCount == 0)
    }

    // MARK: Marks

    @Test func marksOfALongListCostNothingAndTheFiguresAreRight() {
        let count = 200_000
        let model = panel(sample(count))
        model.selectAll()
        #expect(model.selectionCount == count && model.totals == counted(model))
        model.toggleSelection(row: model.row(ofName: "file7.md")!)
        model.invertSelection()
        #expect(model.selectedNames == ["file7.md"] && model.totals == counted(model))
        model.invertSelection()
        #expect(model.selectionCount == count - 1 && model.totals == counted(model))
        model.saveSelection()
        model.select(where: { $0.isFolder }, select: false)
        #expect(
            model.selectionCount == count - 1 - count / 10 && model.totals == counted(model)
                && model.totals.selectedFolders == 0)
        model.select(mask: "*.txt", select: false)
        #expect(model.operands().allSatisfy { $0.name.hasSuffix(".md") } && model.totals == counted(model))
        model.restoreSelection()
        #expect(model.selectionCount == count - 1 && !model.isSelected(row: model.row(ofName: "file7.md")!))
        // With a filter on, everything means everything shown.
        model.setFilter(.mask("*.txt"))
        model.selectAll()
        #expect(model.selectionCount == model.items.count && model.totals == counted(model))
        model.invertSelection()
        #expect(model.selectionCount == 0 && !model.hasSelection)
        // A set of rows found on another thread.
        let basis = model.basis
        let rows = elsewhere { PanelModel.rows(of: basis) { !$0.isFolder && $0.size > 50 } }
        #expect(model.setSelection(rows) && model.selectionCount == rows.count && rows.count > 0)
        #expect(
            model.operands().allSatisfy { $0.size > 50 && $0.name.hasSuffix(".txt") } && model.totals == counted(model))
        #expect(model.setSelection(rows, .remove) && model.selectionCount == 0)
        #expect(model.setSelection(rows, .add) && model.selectionCount == rows.count)
    }

    @Test func theSameNameTwiceIsTwoEntriesEverywhere() {
        // A list gathered from several folders: two files of the very same name.
        let (first, second) = (URL(fileURLWithPath: "/review2/a"), URL(fileURLWithPath: "/review2/b"))
        for others in [0, 300] {
            let items =
                [
                    file("twin.txt", size: 2, in: first), file("twin.txt", size: 5, in: second),
                    file("single.txt", size: 1)
                ]
                + (0..<others).map { file("other\($0).txt") }
            let model = panel(items)
            let rows = model.items.indices.filter { model.items[$0].name == "twin.txt" }.map { $0 + 1 }
            #expect(rows.count == 2)
            // A mark on a row is a mark on that entry: the figures, the count and the operands agree,
            // whether or not the model has made its index of names yet.
            model.toggleSelection(row: rows[1])
            #expect(model.selectionCount == 1 && model.totals.selectedFiles == 1 && model.operands().count == 1)
            #expect(model.totals.selectedBytes == model.operands()[0].size && model.totals == counted(model))
            #expect(model.isSelected(model.items[rows[1] - 1]) && !model.isSelected(model.items[rows[0] - 1]))
            // A name stands for every entry written like it.
            model.clearSelection()
            model.setSelected(true, names: ["twin.txt"])
            #expect(
                model.selectionCount == 2 && model.totals.selectedFiles == 2 && model.totals.selectedBytes == 7
                    && model.operands().count == 2)
            for _ in 0..<4 { _ = model.row(ofName: "single.txt") }
            #expect(model.totals == counted(model) && model.selectionCount == 2)
            model.setSelected(false, names: ["twin.txt"])
            #expect(model.selectionCount == 0 && model.totals.selectedBytes == 0)
            // The marks stay with their entries through another order and another reading.
            model.toggleSelection(row: rows[1])
            let marked = model.operands()[0].url
            model.setSort(ListOrder(key: .size, descending: true))
            #expect(model.operands().map(\.url) == [marked] && model.totals == counted(model))
            model.update(with: listing(items + [file("more.txt")]))
            #expect(model.operands().map(\.url) == [marked] && model.selectionCount == 1)
        }
    }

    @Test func namesThatReadTheSameAreToldApartByWhoeverAsksForTheNamesAsWritten() {
        let (composed, decomposed) = ("caf\u{E9}.txt", "cafe\u{301}.txt")
        let model = panel([file(composed, size: 2), file(decomposed, size: 3), file("plain.txt")])
        model.selectAll()
        #expect(model.selectionCount == 3 && model.selectedNames.count == 3)
        #expect(Set(model.selectedNames.map { Array($0.utf8) }).count == 3)
        // The set of `String`s cannot hold both, as its documentation says.
        #expect(model.selection.count == 2)
    }

    // MARK: Calculated sizes

    @Test func sizesGoToTheSameEntryInBothListsWhateverTheFilter() {
        // Twins in writing, one of them hidden by the filter: the reproducer of the fuzzer.
        let (composed, decomposed) = ("d\u{E9}", "de\u{301}")
        let items = [dir(composed), dir(decomposed), dir("plain"), file("x.txt")] + (0..<200).map { dir("f\($0)") }
        let model = panel(items)
        model.setFilter(PanelFilter(title: "not decomposed") { !ExactName.areSame($0.name, decomposed) })
        model.setComputedSizes([
            (name: decomposed, size: 11), (name: composed, size: 22), (name: "plain", size: 33), (name: "f7", size: 7)
        ])
        func sizes(_ items: [FileItem]) -> [[UInt8]: Int64] {
            Dictionary(
                uniqueKeysWithValues: items.compactMap { item in item.computedSize.map { (Array(item.name.utf8), $0) } }
            )
        }
        #expect(
            sizes(model.listedItems) == [
                Array(decomposed.utf8): 11, Array(composed.utf8): 22, Array("plain".utf8): 33, Array("f7".utf8): 7
            ])
        #expect(sizes(model.items) == [Array(composed.utf8): 22, Array("plain".utf8): 33, Array("f7".utf8): 7])
        #expect(model.totals == counted(model) && model.totals.totalBytes == 22 + 33 + 7 + 1)
        // What is shown is still the listed entries the filter lets through, sizes and all.
        let shown = model.listedItems.filter { model.filter!.matches($0) }
        #expect(shown.map(\.computedSize) == model.items.map(\.computedSize))
        model.setFilter(nil)
        #expect(sizes(model.items) == sizes(model.listedItems) && model.totals.totalBytes == 11 + 22 + 33 + 7 + 1)
    }

    @Test func manySizesWithAFilterOnTakeOnePassNotOnePerName() {
        // Ten thousand sizes in a list of sixty thousand with a filter: one walk of the list
        // per name would be six hundred million comparisons.
        let items = (0..<60_000).map { $0 % 2 == 0 ? dir("dir\($0)") : file("file\($0).txt") }
        let model = panel(items)
        model.setFilter(PanelFilter(title: "even") { $0.isFolder })
        let sizes = (0..<10_000).map { (name: "dir\($0 * 2)", size: Int64($0)) }
        model.setComputedSizes(sizes)
        #expect(model.totals.totalBytes == Int64((0..<10_000).reduce(0, +)))
        #expect(model.item(atRow: model.row(ofName: "dir19998")!)?.computedSize == 9_999)
        #expect(model.listedItems.filter { $0.computedSize != nil }.count == 10_000)
    }

    @Test func sizesSurviveARefreshASortAndAStreamedList() {
        let items = sample(300)
        let model = panel(items)
        model.setComputedSizes([(name: "dir0", size: 5), (name: "dir290", size: 9)])
        model.update(with: listing(Array(items.dropFirst(3)) + [dir("dir0"), file("fresh.txt")]))
        #expect(
            model.listedItems.first { $0.name == "dir0" }?.computedSize == 5
                && model.listedItems.first { $0.name == "dir290" }?.computedSize == 9)
        model.setSort(
            ListOrder(key: .date),
            presorted: Sorter.sort(
                model.listedItems.map {
                    FileItem(url: $0.url, name: $0.name, isDirectory: $0.isDirectory, size: $0.size)
                }, by: ListOrder(key: .date)))
        #expect(model.listedItems.filter { $0.computedSize != nil }.map(\.name).sorted() == ["dir0", "dir290"])
        #expect(model.totals == counted(model))
    }

    // MARK: Snapshots and copies

    @Test func aSnapshotBringsBackTheFilterAndAnswersToThePresentOrder() {
        let items = sample(1_000)
        let model = panel(items)
        let filter = PanelFilter(title: "7") { $0.name.contains("7") }
        model.setFilter(filter)
        model.setSelected(true, names: ["file7.md", "file17.md"])
        let shown = model.items.map(\.name)
        let snapshot = model.snapshot()
        #expect(snapshot.filter?.title == "7" && snapshot.sort == ListOrder())
        // The shell drops the quick filter, opens another folder, the order is changed meanwhile,
        // and the reading fails.
        model.setFilter(nil)
        model.open(URL(fileURLWithPath: "/review2/elsewhere"), parent: folder, root: URL(fileURLWithPath: "/"))
        model.setSort(ListOrder(key: .size, descending: true))
        model.restore(snapshot)
        #expect(model.filter?.title == "7" && model.items.count == shown.count && model.listedItems.count == 1_000)
        #expect(
            Set(model.items.map(\.name)) == Set(shown) && model.selectedNames.sorted() == ["file17.md", "file7.md"])
        // The list is in the order the panel names.
        #expect(model.sort == ListOrder(key: .size, descending: true))
        #expect(model.listedItems.map(\.name) == Sorter.sort(items, by: model.sort).map(\.name))
        #expect(model.items.map(\.name) == Sorter.sort(items, by: model.sort).filter(filter.matches).map(\.name))
        // Turning the direction round turns it round.
        model.setSort(ListOrder(key: .size))
        #expect(model.listedItems.map(\.name) == Sorter.sort(items, by: ListOrder(key: .size)).map(\.name))
        #expect(model.totals == counted(model))
    }

    @Test func aCopyOfATabThatIsStillLoadingSaysSo() {
        let model = PanelModel(directory: folder)
        model.show(listing(sample(20)), complete: false)
        let copy = model.duplicate()
        #expect(!copy.isComplete && copy.items.count == 20 && copy.selectionCount == 0)
        copy.selectAll()
        #expect(copy.selectionCount == 20)
        model.finishLoading()
        #expect(model.duplicate().isComplete)
        let remembered = PanelModel(directory: folder)
        remembered.showRemembered(listing(sample(20)))
        #expect(remembered.duplicate().isRefreshing)
    }

    @Test func savedMarksAreFoundAgainInAnotherFolder() {
        let model = panel(sample(100))
        model.setSelected(true, names: ["file1.md", "file2.md", "dir10"])
        model.saveSelection()
        #expect(model.savedSelection == ["file1.md", "file2.md", "dir10"])
        let other = URL(fileURLWithPath: "/review2/other")
        model.show(
            listing(
                [
                    file("file2.md", in: other), file("zzz", in: other),
                    FileItem(url: other.appendingPathComponent("dir10"), name: "dir10", isDirectory: true)
                ], at: other))
        #expect(model.savedSelection == ["file1.md", "file2.md", "dir10"])
        model.restoreSelection()
        #expect(model.selectedNames.sorted() == ["dir10", "file2.md"])
        // A long saved selection is kept without making its names on the way out.
        let long = panel(sample(30_000))
        long.selectAll()
        long.saveSelection()
        long.show(listing(sample(40_000)))
        long.restoreSelection()
        #expect(long.selectionCount == 30_000)
    }

    @Test func aRangeFarLongerThanTheListMarksTheList() {
        let model = panel(sample(50))
        model.setSelected(true, rows: Int.min...Int.max)
        #expect(model.selectionCount == 50)
        // Ranges that lie outside the list altogether mark nothing and stop nothing.
        model.setSelected(false, rows: 60...70)
        model.setSelected(false, rows: -9...(-3))
        model.setSelected(false, rows: 51...51)
        #expect(model.selectionCount == 50)
        model.setSelected(false, rows: 0...0)
        #expect(model.selectionCount == 50)
        model.setSelected(false, rows: 1...3)
        #expect(model.selectionCount == 47)
    }
}
