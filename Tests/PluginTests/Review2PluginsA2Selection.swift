import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import SelectionPlugin

/// Round 2 of the review, second pass, Selection: the masks on bytes, marking through the model's bulk calls, results
/// for a list that changed meanwhile, and the comparison of the two panels by index.
@MainActor
@Suite
internal struct Review2PluginsA2Selection {
    /// The identifiers of the commands of the Selection plugin.
    internal typealias Ids = SelectionCommands

    /// The file system the panels show.
    internal let memory = MemoryFileSystem()
    private let scratch = ScratchPasteboard()

    /// A pasteboard of the test's own, in place of the clipboard.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }

    /// A file of the folder `/x` named `name`, with `size` bytes, changed `seconds` after 1970, or a folder.
    private static func file(_ name: String, size: Int64 = 1, seconds: TimeInterval = 0, folder: Bool = false)
        -> FileItem
    {
        FileItem(
            url: URL(fileURLWithPath: "/x/" + name),
            name: name,
            kind: .init(isDirectory: folder),
            stat: .init(size: size, modified: Date(timeIntervalSince1970: seconds))
        )
    }

    /// A bench with the Selection plugin over `memory`; with `background` its work runs off the main thread.
    internal func makeBench(background: Bool) -> TestBench {
        TestBench(
            plugins: [SelectionPlugin(pasteboard: pasteboard, background: background)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// Gives the main run loop the time to hand the result of background work back.
    internal func settle(_ condition: () -> Bool) async {
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while !condition(), Date() < patience {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// The matcher on bytes gives the answers of the matcher on characters, for every pattern on every name.
    @Test
    internal func theByteMatcherGivesTheAnswersOfTheCharacterMatcher() {
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
                    SelectionMask(pattern).matches(MaskEntry(name: name)) { false } == expected,
                    "\(pattern.debugDescription) on \(name.debugDescription)"
                )
            }
        }
        // Several masks, an exclusion and folders-only masks keep their meaning.
        let mask = SelectionMask("*.txt *.md | draft*")
        #expect(
            mask.matches("a.txt", isFolder: false) && mask.matches("B.MD", isFolder: false)
                && !mask.matches("draft.txt", isFolder: false) && !mask.matches("a.png", isFolder: false)
        )
        #expect(
            SelectionMask("sub/").matches("sub", isFolder: true)
                && !SelectionMask("sub/").matches("sub", isFolder: false)
        )
    }

    /// A folder read again while a mask is worked out gets the mask on the list as it is now.
    @Test
    internal func aListThatChangesWhileAMaskIsWorkedOutGetsTheMaskAfterwards() async {
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

    /// A panel that goes to another folder while a mask is worked out marks nothing there.
    @Test
    internal func aPanelThatGoesToAnotherFolderMeanwhileDropsTheResult() async {
        memory.addFile("/A/alpha.txt")
        memory.addFile("/B/alpha.txt")
        let bench = makeBench(background: true)
        bench.left.show(memory.url("/A"), focus: nil, history: .keep, completion: nil)
        bench.commands.perform(.selectGroup, .text("<alpha"))
        bench.left.show(memory.url("/B"), focus: nil, history: .record, completion: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(bench.left.model.selectionCount == 0)
    }

    /// Inverting, selecting and clearing the files leave the folders' marks alone; Select All Folders marks folders.
    @Test
    internal func selectingFilesOnlyAndInvertingThemLeavesTheFoldersAlone() {
        for name in ["a.txt", "b.txt", "c.txt"] {
            memory.addFile("/A/" + name)
        }
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

    /// A step given to Select All Files marks every nth line from the cursor, downwards or upwards.
    @Test
    internal func aStepSelectsEveryNthLineFromTheCursor() {
        for name in ["a", "b", "c", "d", "e", "f"] {
            memory.addFile("/A/\(name).txt")
        }
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

    /// A long list is marked in the background through the model's bulk calls: by mask, by extension, inverted and
    /// restored.
    @Test
    internal func aLongListIsMarkedByTheModelsBulkCallsWithoutBlocking() async {
        for index in 0..<(Selections.longList + 100) {
            memory.addFile("/A/f\(index).txt")
        }
        for index in 0..<50 {
            memory.addFile("/A/g\(index).md")
        }
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

    /// Of two names that look the same, a line on the clipboard marks the one written with the same bytes.
    @Test
    internal func theEntryWrittenLikeALineIsTheOneThatIsMarked() async {
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

    /// The comparison by index gives the names of the comparison by name in every mode, and stops when cancelled.
    @Test
    internal func theIndexedComparisonIsTheComparisonByName() {
        let left = [
            Self.file("a"), Self.file("b", seconds: 100), Self.file("c", size: 5), Self.file("d", folder: true),
            Self.file("only left"), Self.file("same", seconds: 7)
        ]
        let right = [
            Self.file("a", seconds: 50), Self.file("b"), Self.file("c"), Self.file("d", folder: true),
            Self.file("only right"), Self.file("same", seconds: 7)
        ]
        for mode in [DirectoryComparison.Mode.newerOrDifferent, .missing, .sizeOrMissing, .newer] {
            for withFolders in [false, true] {
                let names = DirectoryComparison.compare(
                    left: left,
                    right: right,
                    options: .init(mode: mode, withSubdirectories: withFolders)
                )
                let indices = DirectoryComparison.compareIndices(
                    left: left,
                    right: right,
                    options: .init(mode: mode, withSubdirectories: withFolders)
                ) { false }
                #expect(Set(indices.left.map { left[$0].name }) == names.left)
                #expect(Set(indices.right.map { right[$0].name }) == names.right)
                #expect(
                    Set(indices.sameLeft.map { left[$0].name } + indices.sameRight.map { right[$0].name }) == names.same
                )
            }
        }
    }

    /// A comparison that is cancelled stops at once.
    @Test
    internal func aCancelledComparisonStopsAtOnce() {
        let many = (0..<20_000).map { Self.file("n\($0)") }
        let cancelled = DirectoryComparison.compareIndices(
            left: many,
            right: many,
            options: .init(mode: .newer)
        ) { true }
        #expect(cancelled.left.isEmpty && cancelled.sameLeft.count < many.count)
    }

    /// Mark Newer, Hide Same hides the files that are the same on both sides and marks the rest; chosen again it
    /// shows the whole lists.
    @Test
    internal func markNewerLeavesTheSameFilesOutAndMarksTheRest() async {
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
                && bench.right.model.selection == ["only_right.txt"]
        )
        #expect(bench.commands.isChecked(Ids.markNewerHideSame))
        // Chosen again, the lists are whole again.
        bench.commands.perform(Ids.markNewerHideSame)
        #expect(
            bench.left.model.filter == nil && bench.left.model.items.count == 2 && bench.right.model.items.count == 3
        )
    }
}
