import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import SelectionPlugin

/// The Mark menu's work off the main thread beyond the other suites: a long clipboard, panels
/// that change while the work is done, and comparisons of local folders and of roots.
@MainActor
@Suite(.serialized)
internal struct CoverageSelectionBackground {
    /// The commands of this plugin.
    private typealias Ids = SelectionCommands

    /// The files: `/A` and `/B` with a file each.
    private let memory = MemoryFileSystem()
    /// The clipboard the plugin reads.
    private let scratch = ScratchPasteboard()
    /// The kernel with the plugin, working in the background.
    private let bench: TestBench

    /// The kernel's commands.
    private var commands: CommandRegistry { bench.commands }
    /// The panel on `/A`, the source.
    private var left: FakePanel { bench.left }

    /// The files and the kernel.
    internal init() {
        let time = Date(timeIntervalSince1970: 1_000_000)
        memory.addFile("/A/one.txt", "1", modified: time)
        memory.addFile("/A/new.txt", "new", modified: time)
        memory.addFile("/B/one.txt", "1", modified: time)
        bench = TestBench(
            plugins: [SelectionPlugin(pasteboard: scratch.pasteboard)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// Lets the main thread run what was handed to it, one pass of its run loop at a time,
    /// doing `between` before each pass, until `condition` holds; false after `Wait.ceiling`.
    private func pass(until condition: () -> Bool, between: (() -> Void)? = nil) -> Bool {
        let end = Date(timeIntervalSinceNow: Wait.ceiling)
        while !condition() {
            guard Date() < end else {
                return false
            }
            between?()
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        return true
    }

    /// A clipboard too long to be read here is matched in the background.
    @Test
    internal func aLongClipboardIsMatchedInTheBackground() async {
        let text = String(repeating: "x\n", count: Selections.longList * 4) + "one.txt"
        scratch.pasteboard.clearContents()
        scratch.pasteboard.setString(text, forType: .string)
        commands.perform(Ids.loadSelectionFromClipboard)
        #expect(left.model.selection.isEmpty)
        // The names come back through the main queue, which runs between the awaits.
        let end = Date(timeIntervalSinceNow: Wait.ceiling)
        while left.model.selection.isEmpty, Date() < end {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(left.model.selection == ["one.txt"])
    }

    /// A list that changes while Mark Newer works on it is worked on again.
    @Test
    internal func markNewerStartsAgainWhenAListChanged() {
        commands.perform(Ids.markNewerHideSame)
        memory.addFile("/A/later.txt", "later")
        left.reload()
        #expect(pass { commands.isChecked(Ids.markNewerHideSame) })
        #expect(left.model.selection == ["later.txt", "new.txt"] && left.names == ["later.txt", "new.txt"])
    }

    /// A list that keeps changing faster than the work is done is given up after a few tries.
    /// (Each round changes the list before the main thread takes the next result: the list is
    /// long, so the work on it is not done before.)
    @Test
    internal func aListThatKeepsChangingIsGivenUp() {
        for index in 0...Selections.longList { memory.addFile("/A/f\(index).bin") }
        left.reload()
        var rejected = 0
        commands.onRejected = { rejected += 1 }
        commands.perform(.selectGroup, .text("*.txt"))
        var round = 0
        let given = pass(
            until: { rejected > 0 },
            between: {
                round += 1
                memory.addFile("/A/more\(round).txt")
                left.reload()
            }
        )
        #expect(given && rejected == 1 && left.model.selection.isEmpty)
    }

    /// Mark Newer at the roots names the comparison after the roots.
    @Test
    internal func markNewerAtTheRoots() {
        left.show(memory.url("/"))
        bench.right.show(memory.url("/"))
        commands.perform(Ids.markNewerHideSame)
        #expect(pass { commands.isChecked(Ids.markNewerHideSame) })
        #expect(left.model.filter?.title == "Comparison: mem:/*.*")
    }

    /// Local folders are asked whether they tell the cases apart.
    @Test
    internal func localFoldersAreAskedAboutCase() throws {
        let box = try Sandbox()
        let time = Date(timeIntervalSince1970: 1_000_000)
        try box.file("L/Photo.JPG", "x", modified: time)
        try box.file("L/only.txt", "x", modified: time)
        try box.file("R/photo.jpg", "x", modified: time)
        left.show(box.url("L"))
        bench.right.show(box.url("R"))
        commands.perform(Ids.compareDirectories)
        let folds =
            (try? box.url("L").resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames == false
        #expect(pass { left.model.selection.contains("only.txt") })
        // On a volume that folds case the two are one file, the same on both sides.
        #expect(left.model.selection.contains("Photo.JPG") != folds)
        #expect(bench.right.model.selection.contains("photo.jpg") != folds)
    }
}
