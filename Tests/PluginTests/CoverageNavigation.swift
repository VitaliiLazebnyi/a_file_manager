import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import NavigationPlugin

/// The corners of the navigation commands the other suites leave out: entering what is under
/// the cursor, a cancelled or empty way to a folder, and a volume list with nowhere else to go.
@MainActor
@Suite
internal struct CoverageNavigation {
    /// The files: `/A` with a file and a folder, `/B`, and a home folder.
    private let memory = MemoryFileSystem()
    /// The clipboard the plugin reads.
    private let scratch = ScratchPasteboard()
    /// The kernel with the navigation plugin; the panels show `/A` and `/B`.
    private let bench: TestBench

    /// The kernel's commands.
    private var commands: CommandRegistry { bench.commands }
    /// The panel on `/A`, the source.
    private var left: FakePanel { bench.left }

    /// A kernel whose only file system is `memory`.
    internal init() {
        memory.addFile("/A/one.txt")
        memory.addFile("/A/docs/in.txt")
        memory.addFile("/B/other.txt")
        memory.addDirectory("/home")
        bench = TestBench(
            plugins: [NavigationPlugin(pasteboard: scratch.pasteboard, home: memory.url("/home"))],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// Open Directory or Package enters a folder; on a file that nothing opens it is refused.
    @Test
    internal func openDirectoryEntersFoldersAndRefusesAFileNothingOpens() {
        var rejected = 0
        commands.onRejected = { rejected += 1 }
        left.moveCursor(toName: "one.txt")
        commands.perform(.goToDirectory)
        #expect(left.model.directory.path == "/A" && rejected == 1)
        left.moveCursor(toName: "docs")
        commands.perform(.goToDirectory)
        #expect(left.model.directory.path == "/A/docs" && rejected == 1)
    }

    /// Go to Folder shows the folder typed, and a cancelled prompt leaves the panel where it is.
    @Test
    internal func goToFolderFollowsThePromptAndStaysWhenItIsCancelled() {
        bench.interaction.promptAnswers = [.cancel, .text("mem:/B")]
        commands.perform(.editPath)
        #expect(left.model.directory.path == "/A" && bench.interaction.log == ["prompt: Go to folder: [mem:/A]"])
        commands.perform(.editPath)
        #expect(left.model.directory.path == "/B")
    }

    /// A clipboard holding only blank lines offers the command but goes nowhere; a path is read
    /// once and used again while the clipboard stays the same.
    @Test
    internal func blankClipboardGoesNowhereAndAPathIsUsedAgainUnchanged() {
        scratch.pasteboard.clearContents()
        scratch.pasteboard.setString("   \n  ", forType: .string)
        #expect(commands.isEnabled("afm_CdFromClipboard"))
        commands.perform("afm_CdFromClipboard")
        #expect(left.model.directory.path == "/A")
        scratch.pasteboard.clearContents()
        scratch.pasteboard.setString("docs", forType: .string)
        commands.perform("afm_CdFromClipboard")
        #expect(left.model.directory.path == "/A/docs")
        left.show(memory.url("/A"))
        commands.perform("afm_CdFromClipboard")
        #expect(left.model.directory.path == "/A/docs")
    }

    /// With one volume, and the panel on it, there is no next volume: the command is refused.
    @Test
    internal func theNextVolumeIsRefusedWhenThereIsNoOther() {
        var rejected = 0
        commands.onRejected = { rejected += 1 }
        left.show(memory.url("/"))
        commands.perform("cm_GoToNextDrive")
        #expect(rejected == 1 && left.model.directory.path == "/")
    }

    /// A directory outside every place starts the cycle at the first place going forward and
    /// at the last going back.
    @Test
    internal func aDirectoryOutsideEveryPlaceStartsAtEitherEnd() {
        let places = [
            Place(name: "One", url: URL(fileURLWithPath: "/Volumes/One"), kind: .externalDisk),
            Place(name: "Two", url: URL(fileURLWithPath: "/Volumes/Two"), kind: .externalDisk)
        ]
        let outside = URL(string: "mem:/elsewhere") ?? URL(fileURLWithPath: "/")
        #expect(NavigationPlugin.neighbourPlace(of: outside, in: places, delta: 1)?.name == "One")
        #expect(NavigationPlugin.neighbourPlace(of: outside, in: places, delta: -1)?.name == "Two")
    }

    /// A clipboard text with no line on it has no path.
    @Test
    internal func aTextWithoutALineHasNoPath() {
        #expect(NavigationPlugin.path(fromClipboard: "") == nil)
        #expect(NavigationPlugin.path(fromClipboard: "\n\n\r\n") == nil)
    }
}
