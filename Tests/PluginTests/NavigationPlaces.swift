import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import NavigationPlugin

/// The navigation commands beyond the basics: the other panel, volumes, the Mac's standard
/// places and the clipboard.
@MainActor
@Suite
internal struct NavigationPlaces {
    /// The home folder and the two folders the panels start in.
    internal let memory = MemoryFileSystem()
    /// A second volume, for Next and Previous Volume.
    internal let other = MemoryFileSystem(scheme: "disk")
    private let scratch = ScratchPasteboard()
    /// The test's own clipboard, which the plugin reads.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }
    /// A kernel with the navigation plugin, left in `/A`, right in `/B`.
    internal let bench: TestBench

    /// The bench's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The left panel, the source.
    internal var left: FakePanel { bench.left }
    /// The right panel, the target.
    internal var right: FakePanel { bench.right }

    /// Fills the file systems and starts the bench.
    internal init() {
        memory.addFile("/home/Desktop/note.txt")
        memory.addFile("/home/Documents/letter.txt")
        memory.addFile("/home/Downloads/setup.dmg")
        memory.addFile("/home/.Trash/old.txt")
        memory.addFile("/A/one.txt")
        memory.addFile("/A/docs/in.txt")
        memory.addFile("/B/other.txt")
        other.addFile("/data/x.bin")
        bench = TestBench(
            plugins: [NavigationPlugin(pasteboard: scratch.pasteboard, home: memory.url("/home"))],
            fileSystems: [memory, other],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// The specification's keys are bound without a clash, and every menu entry is a registered command.
    @Test
    internal func registersTheSpecificationsKeysWithoutConflicts() {
        let keys = bench.kernel.keyBindings
        #expect(
            keys.command(for: Shortcut(.leftArrow, .control)) == "cm_TransferLeft"
                && keys.command(for: Shortcut(.rightArrow, .control)) == "cm_TransferRight"
        )
        #expect(keys.command(for: Shortcut(.character("u"), .control)) == .exchangePanels)
        #expect(keys.command(for: Shortcut(.character("r"), .control)) == .reread)
        #expect(keys.command(for: Shortcut(.character("\\"), .control)) == .goToRoot)
        #expect(bench.kernel.keyClashes.isEmpty)
        let inMenus = bench.kernel.menus.menus.flatMap(\.items).compactMap(\.self)
        #expect(
            inMenus.allSatisfy { commands[$0] != nil } && inMenus.contains("afm_GoDesktop")
                && inMenus.contains("cm_GoToNextDrive")
        )
        #expect(
            bench.kernel.toolbar.defaultLayout.compactMap { $0?.command } == [
                .goBack, .goForward, .goToParent, .reread
            ]
        )
    }

    /// Ctrl+← / Ctrl+→ show the folder under the cursor, or the current directory, in the panel on that side.
    @Test
    internal func showsTheFolderUnderTheCursorInTheOtherPanel() {
        left.moveCursor(toName: "docs")
        commands.perform("cm_TransferRight")
        #expect(right.model.directory.path == "/A/docs" && left.model.directory.path == "/A")
        // Not on a folder: the current directory.
        left.moveCursor(toName: "one.txt")
        commands.perform("cm_TransferRight")
        #expect(right.model.directory.path == "/A")
        // Towards the panel the cursor is in: that panel takes the other one's directory.
        right.show(memory.url("/B"))
        commands.perform("cm_TransferLeft")
        #expect(left.model.directory.path == "/B")
        right.focus()
        right.show(memory.url("/A"))
        right.moveCursor(toName: "docs")
        commands.perform("cm_TransferLeft")
        #expect(left.model.directory.path == "/A/docs")
    }

    /// Target = Source and Source = Target copy the directory from one panel to the other.
    @Test
    internal func mirrorsThePathEitherWay() {
        commands.perform(.targetEqualsSource)
        #expect(right.model.directory.path == "/A")
        right.show(memory.url("/B"))
        commands.perform("afm_MatchTrg")
        #expect(left.model.directory.path == "/B")
    }

    /// The commands of the standard places and Home show those folders of the home folder.
    @Test
    internal func goesToTheStandardPlaces() {
        for (command, path) in [
            ("afm_GoDesktop", "/home/Desktop"), ("afm_GoDocuments", "/home/Documents"),
            ("afm_GoDownloads", "/home/Downloads"),
            ("afm_GoTrash", "/home/.Trash")
        ] {
            commands.perform(CommandID(rawValue: command))
            #expect(left.model.directory.path == path)
        }
        commands.perform(.goHome)
        #expect(left.model.directory.path == "/home" && left.failures.isEmpty)
        #expect(
            commands[CommandID(rawValue: "afm_GoApplications")] != nil
                && commands[CommandID(rawValue: "afm_GoVolumes")] != nil
        )
    }

    /// Next and Previous Volume go round the volumes, wrapping at the ends.
    @Test
    internal func cyclesThroughTheVolumes() {
        commands.perform("cm_GoToNextDrive")
        #expect(left.model.directory == other.url("/"))
        commands.perform("cm_GoToNextDrive")
        #expect(left.model.directory == memory.url("/"))
        left.show(other.url("/data"))
        commands.perform("cm_GoToPreviousDrive")
        #expect(left.model.directory == memory.url("/"))
    }

    /// The neighbour place cycles over the disks when there are several, over every place otherwise.
    @Test
    internal func choosesTheNeighbourPlace() {
        func place(_ name: String, _ path: String, _ kind: Place.Kind) -> Place {
            Place(name: name, url: URL(fileURLWithPath: path), kind: kind)
        }
        let places = [
            place("Home", "/Users/x", .home), place("Desktop", "/Users/x/Desktop", .folder),
            place("Macintosh HD", "/", .internalDisk),
            place("Backup", "/Volumes/Backup", .externalDisk), place("Stick", "/Volumes/Stick", .externalDisk)
        ]
        func next(_ path: String, _ delta: Int) -> String? {
            NavigationPlugin.neighbourPlace(of: URL(fileURLWithPath: path), in: places, delta: delta)?.name
        }
        // With several disks the cycle runs over the disks; a path belongs to the disk that surrounds it most closely.
        #expect(next("/Users/x/Desktop/a", 1) == "Backup" && next("/Volumes/Backup/deep/er", 1) == "Stick")
        #expect(next("/Volumes/Stick", 1) == "Macintosh HD" && next("/", -1) == "Stick")
        let single = Array(places.prefix(3))
        #expect(
            NavigationPlugin.neighbourPlace(of: URL(fileURLWithPath: "/Users/x/Desktop"), in: single, delta: 1)?.name
                == "Macintosh HD"
        )
        #expect(
            NavigationPlugin.neighbourPlace(of: URL(fileURLWithPath: "/Users/x"), in: single, delta: -1)?.name
                == "Macintosh HD"
        )
        #expect(NavigationPlugin.neighbourPlace(of: URL(fileURLWithPath: "/"), in: [places[2]], delta: 1) == nil)
        #expect(NavigationPlugin.neighbourPlace(of: URL(fileURLWithPath: "/x"), in: [], delta: 1) == nil)
    }

    /// Go to Path from Clipboard is offered while the clipboard holds text and follows the path it starts with.
    @Test
    internal func goesToThePathOnTheClipboard() {
        #expect(!commands.isEnabled("afm_CdFromClipboard"))
        pasteboard.clearContents()
        pasteboard.setString("  \"mem:/A/docs\"  \nsecond line", forType: .string)
        #expect(commands.isEnabled("afm_CdFromClipboard"))
        commands.perform("afm_CdFromClipboard")
        #expect(left.model.directory.path == "/A/docs")
        // The path of a file leads to its folder, with the cursor on the file.
        pasteboard.clearContents()
        pasteboard.setString("mem:/A/one.txt", forType: .string)
        commands.perform("afm_CdFromClipboard")
        #expect(left.model.directory.path == "/A" && left.model.cursorItem?.name == "one.txt")
        // A relative path is taken from the current directory.
        pasteboard.clearContents()
        pasteboard.setString("docs", forType: .string)
        commands.perform("afm_CdFromClipboard")
        #expect(left.model.directory.path == "/A/docs")
        #expect(
            NavigationPlugin.path(fromClipboard: " \n") == nil
                && NavigationPlugin.path(fromClipboard: "'/a b'") == "/a b"
        )
    }
}
