import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin
@testable import FindFilesPlugin
@testable import MultiRenamePlugin
@testable import NavigationPlugin
@testable import PlacesPlugin
@testable import SelectionPlugin
@testable import SystemToolsPlugin
@testable import ViewOptionsPlugin
@testable import VirtualFoldersPlugin

/// Round 2, second pass, for Find / Selection / Multi-Rename, Configuration, Places: the
/// Selection plugin on the kernel's bulk marking, sorting that keeps being asked for, the tree
/// cache and the tree, files that are listed in parts, plans that can be cancelled.

// MARK: Selection

@MainActor @Suite struct Review2PluginsA2Selection {
    typealias Ids = SelectionCommands

    let memory = MemoryFileSystem()
    let pasteboard = NSPasteboard.withUniqueName()

    func makeBench(background: Bool) -> TestBench {
        TestBench(
            plugins: [SelectionPlugin(pasteboard: pasteboard, background: background)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"), right: memory.url("/B"))
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<5_000 where !condition() { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    @Test func theByteMatcherGivesTheAnswersOfTheCharacterMatcher() {
        let patterns = ["*.txt", "*.*", "a*", "a?c", "*", "name.", "name.*", "?", "*a*b*", "ab", "A*Z", "é*", "*\r*"]
        let names = [
            "a.txt", "A.TXT", "abc", "ABC", "name", "name.", "name.x", "x", "", "ab", "aXb", "Az", "é", "éa", "a\r\nb",
            "no dot", ".hidden",
            "a.b.c", "AbC", "zzz.txt", "straße", "e\u{301}"
        ]
        for pattern in patterns {
            for name in names {
                // The reference is the matcher that works on characters.
                let expected = Wildcard.matches(Array(pattern.lowercased()), Array(name.lowercased()))
                #expect(
                    SelectionMask(pattern).matches(MaskEntry(name: name)) == expected,
                    "\(pattern.debugDescription) on \(name.debugDescription)")
            }
        }
        // Several masks, an exclusion and folders-only masks keep their meaning.
        let mask = SelectionMask("*.txt *.md | draft*")
        #expect(mask.matches("a.txt") && mask.matches("B.MD") && !mask.matches("draft.txt") && !mask.matches("a.png"))
        #expect(
            SelectionMask("sub/").matches("sub", isFolder: true)
                && !SelectionMask("sub/").matches("sub", isFolder: false))
    }

    @Test func aListThatChangesWhileAMaskIsWorkedOutGetsTheMaskAfterwards() async {
        memory.addFile("/A/alpha.txt")
        let bench = makeBench(background: true)
        bench.left.show(memory.url("/A"), focus: nil, history: .keep, completion: nil)
        bench.commands.perform(.selectGroup, .text("<^al"))
        // The folder is read again before the answer comes back: the command goes on for the list as it is.
        memory.addFile("/A/alpine.txt")
        bench.left.show(memory.url("/A"), focus: nil, history: .keep, completion: nil)
        await settle { bench.left.model.selectionCount == 2 }
        #expect(bench.left.model.selection == ["alpha.txt", "alpine.txt"])
    }

    @Test func aPanelThatGoesToAnotherFolderMeanwhileDropsTheResult() async {
        memory.addFile("/A/alpha.txt")
        memory.addFile("/B/alpha.txt")
        let bench = makeBench(background: true)
        bench.left.show(memory.url("/A"), focus: nil, history: .keep, completion: nil)
        bench.commands.perform(.selectGroup, .text("<alpha"))
        bench.left.show(memory.url("/B"), focus: nil, history: .record, completion: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(bench.left.model.selectionCount == 0)
    }

    @Test func selectingFilesOnlyAndInvertingThemLeavesTheFoldersAlone() {
        for name in ["a.txt", "b.txt", "c.txt"] { memory.addFile("/A/" + name) }
        memory.addDirectory("/A/dir1")
        memory.addDirectory("/A/dir2")
        let bench = makeBench(background: false)
        let model = bench.left.model
        model.setSelected(true, names: ["dir1", "a.txt"])
        bench.commands.perform(Ids.invertFiles)
        #expect(model.selection == ["dir1", "b.txt", "c.txt"])
        bench.commands.perform(.unselectAll)
        bench.commands.perform(Ids.selectAllFiles)
        #expect(model.selection == ["a.txt", "b.txt", "c.txt"])
        bench.commands.perform(Ids.clearAllFiles)
        #expect(model.selectionCount == 0)
        bench.commands.perform(Ids.selectAllFolders)
        #expect(model.selection == ["dir1", "dir2"])
    }

    @Test func aStepSelectsEveryNthLineFromTheCursor() {
        for name in ["a", "b", "c", "d", "e", "f"] { memory.addFile("/A/\(name).txt") }
        let bench = makeBench(background: false)
        let model = bench.left.model
        bench.left.moveCursor(toName: "b.txt")
        bench.commands.perform(Ids.selectAllFiles, .index(2))
        #expect(model.selection == ["b.txt", "d.txt", "f.txt"])
        bench.commands.perform(.unselectAll)
        bench.left.moveCursor(toName: "e.txt")
        bench.commands.perform(Ids.selectAllFiles, .index(-2))
        #expect(model.selection == ["e.txt", "c.txt", "a.txt"])
    }

    @Test func aLongListIsMarkedByTheModelsBulkCallsWithoutBlocking() async {
        for index in 0..<(Selections.longList + 100) { memory.addFile("/A/f\(index).txt") }
        for index in 0..<50 { memory.addFile("/A/g\(index).md") }
        let bench = makeBench(background: true)
        let model = bench.left.model
        bench.left.show(memory.url("/A"), focus: nil, history: .keep, completion: nil)
        bench.commands.perform(.selectGroup, .text("*.md"))
        #expect(model.selectionCount == 0)
        await settle { model.selectionCount == 50 }
        #expect(model.selectionCount == 50)
        // The files of the cursor's extension are added to what is marked.
        bench.left.moveCursor(toName: "f1.txt")
        bench.commands.perform(Ids.selectCurrentExtension)
        await settle { model.selectionCount == model.items.count }
        #expect(model.selectionCount == model.items.count)
        bench.commands.perform(Ids.unselectCurrentExtension)
        await settle { model.selectionCount == 50 }
        #expect(model.selectionCount == 50)
        // Inverting a part of the list and putting the marks back are passes over bits.
        bench.commands.perform(Ids.saveSelection)
        bench.commands.perform(Ids.invertFiles)
        await settle { model.selectionCount == model.items.count - 50 }
        #expect(model.selectionCount == model.items.count - 50 && !model.selection.contains("g1.md"))
        bench.commands.perform(.restoreSelection)
        #expect(model.selectionCount == 50)
    }

    @Test func theEntryWrittenLikeALineIsTheOneThatIsMarked() async {
        let composed = "\u{E9}.txt"
        let decomposed = "e\u{301}.txt"
        memory.addFile("/A/" + composed)
        memory.addFile("/A/" + decomposed)
        memory.addFile("/A/other.txt")
        let bench = makeBench(background: true)
        pasteboard.clearContents()
        pasteboard.setString(decomposed + "\n", forType: .string)
        bench.commands.perform(Ids.loadSelectionFromClipboard)
        await settle { bench.left.model.selectionCount > 0 }
        #expect(bench.left.model.selectionCount == 1 && bench.left.model.selectedNames == [decomposed])
        #expect(bench.left.model.selectedNames.first?.utf8.elementsEqual(decomposed.utf8) == true)
    }

    @Test func theIndexedComparisonIsTheComparisonByName() {
        func file(_ name: String, size: Int64 = 1, seconds: TimeInterval = 0, folder: Bool = false) -> FileItem {
            FileItem(
                url: URL(fileURLWithPath: "/x/" + name), name: name, isDirectory: folder, size: size,
                modified: Date(timeIntervalSince1970: seconds))
        }
        let left = [
            file("a"), file("b", seconds: 100), file("c", size: 5), file("d", folder: true), file("only left"),
            file("same", seconds: 7)
        ]
        let right = [
            file("a", seconds: 50), file("b"), file("c"), file("d", folder: true), file("only right"),
            file("same", seconds: 7)
        ]
        for mode in [DirectoryComparison.Mode.newerOrDifferent, .missing, .sizeOrMissing, .newer] {
            for withFolders in [false, true] {
                let names = DirectoryComparison.compare(
                    left: left, right: right, mode: mode, withSubdirectories: withFolders)
                let indices = DirectoryComparison.compareIndices(
                    left: left, right: right, mode: mode, withSubdirectories: withFolders)
                #expect(Set(indices.left.map { left[$0].name }) == names.left)
                #expect(Set(indices.right.map { right[$0].name }) == names.right)
                #expect(
                    Set(indices.sameLeft.map { left[$0].name } + indices.sameRight.map { right[$0].name }) == names.same
                )
            }
        }
        // A cancelled comparison stops at once.
        let many = (0..<20_000).map { file("n\($0)") }
        let cancelled = DirectoryComparison.compareIndices(left: many, right: many, cancelled: { true })
        #expect(cancelled.left.isEmpty && cancelled.sameLeft.count < many.count)
    }

    @Test func markNewerLeavesTheSameFilesOutAndMarksTheRest() async {
        memory.addFile("/A/same.txt", "1", modified: Date(timeIntervalSince1970: 10))
        memory.addFile("/B/same.txt", "1", modified: Date(timeIntervalSince1970: 10))
        memory.addFile("/A/newer.txt", "1", modified: Date(timeIntervalSince1970: 500))
        memory.addFile("/B/newer.txt", "1", modified: Date(timeIntervalSince1970: 20))
        memory.addFile("/B/only_right.txt")
        let bench = makeBench(background: true)
        bench.commands.perform(Ids.markNewerHideSame)
        await settle {
            bench.left.model.selectionCount > 0 && bench.right.model.selectionCount > 0
                && bench.left.model.filter != nil
        }
        #expect(bench.left.model.items.map(\.name) == ["newer.txt"] && bench.left.model.selection == ["newer.txt"])
        #expect(
            bench.right.model.items.map(\.name) == ["newer.txt", "only_right.txt"]
                && bench.right.model.selection == ["only_right.txt"])
        #expect(bench.commands.isChecked(Ids.markNewerHideSame))
        // Chosen again, the lists are whole again.
        bench.commands.perform(Ids.markNewerHideSame)
        #expect(
            bench.left.model.filter == nil && bench.left.model.items.count == 2 && bench.right.model.items.count == 3)
    }
}

// MARK: ViewOptions

@MainActor @Suite struct Review2PluginsA2ViewOptions {
    /// Unchecked: used on the main thread only; the plugin hands its steps over there and the
    /// test runs them there.
    final class Steps: @unchecked Sendable {
        var background: [@Sendable () -> Void] = []
        var main: [@MainActor @Sendable () -> Void] = []

        func runBackground() {
            let work = background
            background = []
            work.forEach { $0() }
        }

        @MainActor func runMain() {
            let work = main
            main = []
            work.forEach { $0() }
        }
    }

    let memory = MemoryFileSystem()
    let plugin = ViewOptionsPlugin()
    let steps = Steps()
    let bench: TestBench

    var model: PanelModel { bench.left.model }

    init() {
        for number in 0..<ViewOptionsPlugin.backgroundSortThreshold {
            memory.addFile("/Big/f\(number).txt", String(repeating: "x", count: number % 7))
        }
        memory.addDirectory("/B")
        bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/Big"), right: memory.url("/B"))
        plugin.background = { [steps] in steps.background.append($0) }
        plugin.onMain = { [steps] in steps.main.append($0) }
    }

    @Test func aFolderThatChangesWhileItIsSortedGetsTheOrderWithItsReading() {
        bench.commands.perform(.sortBySize)
        // The wish is the model's; the list is sorted in the background.
        #expect(steps.background.count == 1 && model.sort.key == .name && model.requestedSort?.key == .size)
        // The folder changes before the sort is ready: the reading that arrives is taken in
        // the order that was asked for.
        memory.addFile("/Big/new.txt", "12345678901234567890")
        bench.left.reload()
        #expect(model.sort.key == .size && model.requestedSort == nil)
        steps.runBackground()
        steps.runMain()
        // The sort that was made meanwhile is of no use, and nothing is sorted a second time.
        #expect(model.sort.key == .size && steps.background.isEmpty && steps.main.isEmpty)
        let descending = model.sort.descending
        #expect(
            zip(model.items, model.items.dropFirst()).allSatisfy {
                descending ? $0.size >= $1.size : $0.size <= $1.size
            })
        #expect(model.items.contains { $0.name == "new.txt" })
    }

    @Test func aChangeThatBringsNoListLeavesTheSortToTheBackgroundAgain() {
        bench.commands.perform(.sortBySize)
        // Another filter while the list is sorted: the result is stale, and no reading brought the order.
        model.setFilter(.mask("*.txt"))
        steps.runBackground()
        steps.runMain()
        #expect(model.sort.key == .name && model.requestedSort?.key == .size && steps.background.count == 1)
        steps.runBackground()
        steps.runMain()
        #expect(model.sort.key == .size && model.requestedSort == nil && steps.background.isEmpty && steps.main.isEmpty)
        let descending = model.sort.descending
        #expect(
            zip(model.items, model.items.dropFirst()).allSatisfy {
                descending ? $0.size >= $1.size : $0.size <= $1.size
            })
    }

    @Test func aWishForAnOrderSurvivesAListThatArrivesBeforeItIsMet() {
        bench.commands.perform(.sortByTime)
        bench.commands.perform(.reversedOrder)
        // The second command starts from the order that was asked for, not from the one the panel has.
        steps.runBackground()
        steps.runMain()
        #expect(
            model.sort
                == ListOrder(
                    key: .date,
                    descending: !ListOrder(key: .date, descending: SortKey.date.startsDescending).descending))
    }

    @Test func unsortedAfterAnotherKeyReadsTheFolderAgain() {
        let small = MemoryFileSystem()
        small.addFile("/S/zebra.txt")
        small.addFile("/S/apple.txt")
        small.addFile("/S/mango.txt")
        let bench = TestBench(
            plugins: [ViewOptionsPlugin()], fileSystems: [small], left: small.url("/S"), right: small.url("/S"))
        bench.commands.perform(.sortByName)
        #expect(bench.left.names == bench.left.names.sorted())
        bench.commands.perform(.unsorted)
        // The order the file system gives them in is back.
        let arrival = ((try? small.list(small.url("/S"), showHidden: true)) ?? []).map(\.name)
        #expect(bench.left.model.sort.key == .unsorted && bench.left.names == arrival)
    }

    @Test func onlySelectedFilesTakesTheNamesInTheBackground() {
        model.setSelected(true, names: ["f1.txt", "f3.txt"])
        bench.commands.perform(ViewOptionsPlugin.onlySelected)
        #expect(steps.background.count == 1 && model.filter == nil)
        steps.runBackground()
        steps.runMain()
        #expect(model.items.map(\.name) == ["f1.txt", "f3.txt"])
    }
}

// MARK: Configuration, SystemTools

@Suite struct Review2PluginsA2Configuration {
    let context = ExpansionContext(
        left: PanelSnapshot(path: "/A dir/", cursorName: "my file.txt", selection: ["a.txt", "b\u{2028}c.txt"]),
        right: PanelSnapshot(path: "/B/", cursorName: "other.md"),
        listFolder: URL(fileURLWithPath: "/tmp/lists"), listName: "test")

    @Test func aSubstringOfTheLargestLengthDoesNotTrap() {
        // The reproducer of the fuzzer (`pexpand-substring-length-overflow.bin`) and the same words by hand.
        let repro = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fuzz/repro/misc/pexpand-substring-length-overflow.bin")
        var texts = [
            "%N:~6,9223372036854775807", "%N:~9223372036854775807,9223372036854775807", "%N:~-9223372036854775808,5",
            "%N:~0,-9223372036854775808", "%N:~6,18446744073709551616"
        ]
        if let data = try? Data(contentsOf: repro) { texts.append(String(decoding: data, as: UTF8.self)) }
        for text in texts {
            let expanded = ParameterExpander(context: context).expand(text).text
            #expect(expanded.utf8.count < 200, "\(text)")
        }
        #expect(
            ParameterExpander(context: context).expand("%N:~6,9223372036854775807").text
                == ParameterExpander(context: context).expand("%N:~6,99").text)
    }

    @Test func aNameWithAnyKindOfLineEndIsNotPassedInAListFile() {
        // U+2028 ends a line for the programs that read the list with `splitlines`.
        let expanded = ParameterExpander(context: context).expand("%L")
        #expect(expanded.problem != nil)
    }

    @Test func aUserCommandIsFoundByNameWithoutSearching() {
        let settings = MemorySettings()
        let store = ConfigurationStore(settings: settings)
        var commands: [UserCommand] = []
        for index in 0..<200 {
            commands.append(
                UserCommand(name: "em_\(index)", title: "", action: CommandAction(command: "echo \(index)")))
        }
        commands.append(UserCommand(name: "em_7", title: "", action: CommandAction(command: "echo again")))
        store.userCommands = commands
        #expect(store.userCommand(named: "em_150")?.action.command == "echo 150")
        // Of two commands of one name the first is the one.
        #expect(
            store.userCommand(named: "em_7")?.action.command == "echo 7" && store.userCommand(named: "nothing") == nil)
        store.userCommands = Array(commands.prefix(3))
        #expect(
            store.userCommand(named: "em_150") == nil && store.userCommand(named: "em_1")?.action.command == "echo 1")
    }
}

@MainActor @Suite struct Review2PluginsA2SystemTools {
    @Test func theLongestLineIsMeasuredWithoutCuttingEveryLineIntoCharacters() {
        let pages = [[String(repeating: "e\u{301}", count: 40), "short"], ["x"]]
        let view = PagePrintView(pages: pages, linesPerPage: 60, printInfo: NSPrintInfo())
        var range = NSRange()
        #expect(withUnsafeMutablePointer(to: &range) { view.knowsPageRange($0) } && range.length == 2)
    }
}

// MARK: Places

@Suite struct Review2PluginsA2Places {
    let box = try! Sandbox()
    let root = URL(fileURLWithPath: "/tmp/tree-root/", isDirectory: true)

    @Test func theHotlistLimitHoldsForWhatIsStored() throws {
        var hotlist = Hotlist()
        for index in 0..<(Hotlist.limit + 25) { hotlist.entries.append(.item("t\(index)", command: "cd /x\(index)")) }
        let data = try JSONEncoder().encode(hotlist)
        let report = DecodeReport()
        let decoder = JSONDecoder()
        decoder.userInfo[DecodeReport.key] = report
        let loaded = try decoder.decode(Hotlist.self, from: data)
        #expect(loaded.count == Hotlist.limit && loaded.entries.first?.title == "t0" && report.skipped == 25)
        // Submenus count with what they hold, in display order.
        var nested = Hotlist()
        nested.entries = [
            HotlistEntry(
                kind: .submenu, title: "m",
                children: (0..<(Hotlist.limit + 5)).map { .item("c\($0)", command: "cd /c\($0)") }),
            .item("after", command: "cd /after")
        ]
        let reloaded = try JSONDecoder().decode(Hotlist.self, from: try JSONEncoder().encode(nested))
        #expect(reloaded.count == Hotlist.limit && reloaded.entries.count == 1)
    }

    @Test func aFolderNotedLaterShowsAsNotReadYet() {
        let cache = TreeCache(directory: nil)
        cache.store(["a", "b"], for: root)
        cache.noteFolder("a/new/deeper", below: root)
        cache.waitForUpdates()
        let entry = cache.entry(for: root)
        #expect(entry?.paths.sorted() == ["a", "a/new", "a/new/deeper", "b"])
        #expect(Set(entry?.unscanned ?? []) == ["a/new", "a/new/deeper"])
        let tree = DirectoryTree(rootURL: root, paths: entry?.paths ?? [], unscanned: entry?.unscanned ?? [])
        #expect(tree.node(at: "a/new/deeper")?.isScanned == false && tree.node(at: "b")?.isScanned == true)
    }

    @Test func namesThatBeginWithACombiningMarkComeBackFromTheFile() {
        let paths = ["\u{301}start", "dir", "dir/\u{301}inside", "dir/\u{0300}\u{0301}x", "plain"]
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(paths, unscanned: ["\u{301}start"], for: root)
        let fresh = TreeCache(directory: box.url("cache"))
        let entry = fresh.entry(for: root)
        #expect(entry?.paths == paths && entry?.unscanned == ["\u{301}start"] && entry?.isComplete == true)
        // The same through the text.
        let text = TreeCache.format(TreeCache.Entry(paths: paths, unscanned: ["\u{301}start"]), root: root)
        #expect(TreeCache.parseEntry(text, root: root)?.paths == paths)
        // A name with a combining mark after the slash is found in the tree too.
        let tree = DirectoryTree(rootURL: root, paths: paths)
        #expect(tree.node(at: "dir/\u{301}inside") != nil && tree.count == 5)
    }

    @Test func aTreeOfManyFoldersIsWrittenInPiecesForTheUserAlone() throws {
        let paths = (0..<300_000).map { "folder-\($0)" }
        let cache = TreeCache(directory: box.url("big"))
        cache.store(paths, for: root)
        let file = try #require(cache.fileURL(for: root))
        var info = stat()
        #expect(stat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600 && info.st_size > 4_000_000)
        #expect(TreeCache(directory: box.url("big")).paths(for: root) == paths)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".tmp\(getpid())"))
    }

    @Test func aHugeSetOfTreesInMemoryIsTrimmedByTheNumberOfFolders() {
        let cache = TreeCache(directory: box.url("many"))
        for index in 0..<4 {
            cache.store(
                (0..<600_000).map { "p\($0)" }, for: URL(fileURLWithPath: "/tmp/root\(index)/", isDirectory: true))
        }
        // Not all four are held (that would be more than the limit); each is still there from its file.
        for index in 0..<4 {
            #expect(cache.paths(for: URL(fileURLWithPath: "/tmp/root\(index)/", isDirectory: true))?.count == 600_000)
        }
    }

    @Test func aFolderMadeMeanwhileIsNotLinkedTwiceAndKeepsItsNode() throws {
        let tree = DirectoryTree(rootURL: root)
        let names = (0..<100).map { "a\($0)" }
        let nodes = DirectoryTree.makeNodes(names)
        var done = tree.attach(nodes, ofPath: "", from: 0, limit: 10)
        #expect(done == 10)
        // The window makes the folder of the panel while the scan is still linking.
        let made = try #require(tree.node(at: "a50", creating: true))
        let later = try #require(tree.node(at: "a95", creating: true))
        while done < nodes.count { done = tree.attach(nodes, ofPath: "", from: done, limit: 10) }
        let children = tree.root.children
        #expect(children.count == 100 && Set(children.map(\.name)).count == 100)
        #expect(children.map(\.name) == DirectoryTree.makeNodes(names).map(\.name))
        #expect(children.first { $0.name == "a50" } === made && children.first { $0.name == "a95" } === later)
        #expect(
            tree.count == 100 && children.enumerated().allSatisfy { $0.element.indexInParentForTests == $0.offset }
                && tree.root.isScanned)
        // A folder that was made and is not in the listing has gone.
        let tree2 = DirectoryTree(rootURL: root)
        var at = tree2.attach(Array(DirectoryTree.makeNodes(["x1", "x2", "x3"])), ofPath: "", from: 0, limit: 1)
        _ = tree2.node(at: "ghost", creating: true)
        while at < 3 {
            at = tree2.attach(DirectoryTree.makeNodes(["x1", "x2", "x3"]), ofPath: "", from: at, limit: 1)
        }
        #expect(tree2.root.children.map(\.name) == ["x1", "x2", "x3"] && tree2.count == 3)
    }

    @Test func aFolderThatHadChildrenIsRebuiltInTurnsOfLimitedSize() throws {
        let tree = DirectoryTree(rootURL: root)
        // The way to the folder the window opened is made beforehand, with a stale child.
        let chain = try #require(tree.node(at: "mid/x", creating: true))
        _ = tree.node(at: "mid/gone", creating: true)
        let names = ["x"] + (0..<1_000).map { "n\($0)" }
        let nodes = DirectoryTree.makeNodes(names)
        let mid = try #require(tree.node(at: "mid"))
        var done = tree.attach(nodes, ofPath: "mid", from: 0, limit: 100)
        #expect(done == 100)
        // Until the last turn the folder has what it had, and no turn linked more than the limit.
        #expect(mid.children.count == 2 && !mid.isScanned)
        var turns = 1
        while done < nodes.count {
            done = tree.attach(nodes, ofPath: "mid", from: done, limit: 100)
            turns += 1
        }
        #expect(turns == 11 && mid.children.count == 1_001 && mid.isScanned)
        #expect(mid.children.first { $0.name == "x" } === chain && mid.children.allSatisfy { $0.name != "gone" })
        #expect(
            tree.count == 1 + 1_001
                && mid.children.enumerated().allSatisfy { $0.element.indexInParentForTests == $0.offset })
    }
}

extension TreeNode {
    var indexInParentForTests: Int { parent?.children.firstIndex { $0 === self } ?? -1 }
}

// MARK: Navigation, VirtualFolders

@Suite struct Review2PluginsA2Lists {
    @Test func aPathIsTakenFromTheStartOfAVeryLongClipboardLine() {
        let long = "/Users/me/Documents" + String(repeating: "x", count: 5_000_000)
        let path = NavigationPlugin.path(fromClipboard: long)
        #expect(path?.hasPrefix("/Users/me/Documents") == true && (path?.utf8.count ?? .max) <= 8_192)
        #expect(NavigationPlugin.path(fromClipboard: "\n\n  \"/a b\"  \nsecond") == "/a b")
    }

    @Test func aListThatIsKnownToBeUniqueIsNotLookedThroughForDoubles() {
        let fileSystems = FileSystemRegistry()
        let memory = MemoryFileSystem()
        fileSystems.register(memory)
        let virtual = VirtualFileSystem(fileSystems: fileSystems)
        let files = [memory.url("/a"), memory.url("/b"), memory.url("/a")]
        let plain = virtual.register(files: files, title: "t", origin: nil)
        let unique = virtual.register(files: files, title: "t", origin: nil, isUnique: true)
        #expect(virtual.entries(of: plain)?.count == 2)
        #expect(virtual.entries(of: unique)?.count == 3)
    }
}

// MARK: Find Files

@Suite struct Review2PluginsA2Find {
    @Test func aFolderOfManyFilesReportsItsFirstHitBeforeTheListingEnds() {
        let (fileSystems, memory) = makeFileSystems()
        for index in 0..<60 { memory.addFile(String(format: "/huge/f%02d.txt", index)) }
        memory.listBatchSize = 10
        memory.listBatchDelay = 0.2
        let search = FileSearch(
            SearchQuery(directory: memory.url("/huge")), fileSystems: fileSystems,
            tuning: .init(partialListingAfter: 10))
        let began = Date()
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var firstAt: TimeInterval?
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var found: [String] = []
        let done = DispatchSemaphore(value: 0)
        Thread {
            search.run {
                if firstAt == nil { firstAt = Date().timeIntervalSince(began) }
                found.append($0.name)
            }
            done.signal()
        }.start()
        #expect(done.wait(timeout: .now() + 120) == .success)
        let total = Date().timeIntervalSince(began)
        // Five pauses of 0.2 s lie between the first batch and the last.
        #expect((firstAt ?? total) < total - 0.5)
        #expect(found.count == 60 && Set(found).count == 60)
        // Each part is in name order.
        #expect(found == found.sorted())
    }

    @Test func aFolderListedInPartsStillGivesEveryHitOfTheTestsInOrderOfParts() {
        let (fileSystems, memory) = makeFileSystems()
        for index in 0..<45 { memory.addFile(String(format: "/parts/%@%02d.txt", index % 2 == 0 ? "a" : "b", index)) }
        memory.listBatchSize = 7
        var query = SearchQuery(directory: memory.url("/parts"))
        query.names = "a*"
        var found: [String] = []
        let search = FileSearch(query, fileSystems: fileSystems, tuning: .init(partialListingAfter: 7))
        search.run { found.append($0.name) }
        #expect(
            Set(found) == Set((0..<45).filter { $0 % 2 == 0 }.map { String(format: "a%02d.txt", $0) })
                && found.count == 23)
    }

    @Test func oneShareMountedTwiceIsOnePlace() {
        let first = DuplicateFinder.Mount(from: "smbfs://me@server/share", on: "/Volumes/share")
        let second = DuplicateFinder.Mount(from: "smbfs://me@server/share", on: "/Volumes/share-1")
        #expect(first.place(of: "/Volumes/share/docs/a.txt") == second.place(of: "/Volumes/share-1/docs/a.txt"))
        #expect(first.place(of: "/Volumes/share/docs/a.txt") != first.place(of: "/Volumes/share/docs/b.txt"))
        let other = DuplicateFinder.Mount(from: "smbfs://me@server/other", on: "/Volumes/other")
        #expect(other.place(of: "/Volumes/other/docs/a.txt") != first.place(of: "/Volumes/share/docs/a.txt"))
    }
}

// MARK: Multi-Rename

@Suite struct Review2PluginsA2Rename {
    @Test func aPlanThatIsCancelledIsCutShort() {
        let sources = (0..<40_000).map { URL(fileURLWithPath: "/x/f\($0).txt") }
        let targets: [URL?] = (0..<40_000).map { URL(fileURLWithPath: "/x/g\($0).txt") }
        let planner = RenamePlanner()
        #expect(planner.steps(sources: sources, targets: targets).count == 40_000)
        #expect(planner.steps(sources: sources, targets: targets, cancelled: { true }).isEmpty)
        var calls = 0
        let part = planner.steps(
            sources: sources, targets: targets,
            cancelled: {
                calls += 1
                return calls > 2
            })
        #expect(part.count < 40_000)
    }

    @Test func aRingOfRenamesIsStillOpenedWithATemporaryName() {
        let sources = ["1", "2", "3"].map { URL(fileURLWithPath: "/x/\($0).txt") }
        let targets: [URL?] = ["2", "3", "1"].map { URL(fileURLWithPath: "/x/\($0).txt") }
        let steps = RenamePlanner().steps(sources: sources, targets: targets)
        #expect(
            steps.count == 4 && steps.filter { $0.kind == .park }.count == 1
                && steps.filter { $0.kind == .unpark }.count == 1)
    }

    @Test func theFuzzerReproducersOfTheRenameMasksEnd() {
        // `renamemask-wildcard-backtracking.bin` and `renameregex-catastrophic.bin`: the text after the
        // choice bytes is name mask, extension mask, search, replacement and the name, one to a line.
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fuzz/repro/diff")
        for (file, regex) in [
            ("renamemask-wildcard-backtracking.bin", false), ("renameregex-catastrophic.bin", true)
        ] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { continue }
            let lines = data.dropFirst(13).split(separator: 0x0A, omittingEmptySubsequences: false).map {
                String(decoding: $0, as: UTF8.self)
            }
            var settings = RenameSettings()
            settings.nameMask = lines[0]
            settings.extensionMask = lines[1]
            settings.search = lines[2]
            settings.replacement = lines[3]
            settings.regularExpression = regex
            var context = RenameContext()
            context.count = 3
            let subject = RenameSubject(
                name: lines[4], isFolder: false, size: 1, modified: Date(timeIntervalSince1970: 0), directoryPath: "/d"
            )
            let engine = RenameEngine(settings, context: context)
            let done = DispatchSemaphore(value: 0)
            Thread {
                _ = engine.newName(for: subject, index: 0)
                done.signal()
            }.start()
            #expect(done.wait(timeout: .now() + 60) == .success, "\(file)")
        }
    }

    @Test func twoFilesAreTheSameFileOnlyWhenNothingElseCouldBeMeant() throws {
        let box = try Sandbox()
        let one = try box.file("one.txt")
        let other = try box.file("other.txt")
        #expect(RenameRunner.isSameFileOnDisk(one, one) == true)
        #expect(RenameRunner.isSameFileOnDisk(one, other) == false)
        #expect(RenameRunner.isSameFileOnDisk(one, box.url("missing")) == nil)
        // A file with two names may be two files to the listing: it is left to it.
        let link = box.url("link.txt")
        #expect(
            link.withUnsafeFileSystemRepresentation { target in
                one.withUnsafeFileSystemRepresentation { source in Darwin.link(source!, target!) }
            } == 0)
        #expect(RenameRunner.isSameFileOnDisk(one, link) == nil)
    }
}
