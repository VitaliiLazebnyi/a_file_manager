import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import NavigationPlugin

/// The navigation commands beyond the basics: the other panel, volumes, the Mac's standard
/// places and the clipboard.
@MainActor @Suite struct NavigationPlaces {
    let memory = MemoryFileSystem()
    let other = MemoryFileSystem(scheme: "disk")
    let pasteboard = NSPasteboard.withUniqueName()
    let bench: TestBench

    var commands: CommandRegistry { bench.commands }
    var left: FakePanel { bench.left }
    var right: FakePanel { bench.right }

    init() {
        memory.addFile("/home/Desktop/note.txt")
        memory.addFile("/home/Documents/letter.txt")
        memory.addFile("/home/Downloads/setup.dmg")
        memory.addFile("/home/.Trash/old.txt")
        memory.addFile("/A/one.txt")
        memory.addFile("/A/docs/in.txt")
        memory.addFile("/B/other.txt")
        other.addFile("/data/x.bin")
        bench = TestBench(
            plugins: [NavigationPlugin(pasteboard: pasteboard, home: memory.url("/home"))],
            fileSystems: [memory, other],
            left: memory.url("/A"), right: memory.url("/B"))
    }

    @Test func registersTheSpecificationsKeysWithoutConflicts() {
        let keys = bench.kernel.keyBindings
        #expect(
            keys.command(for: Shortcut(.left, .control)) == "cm_TransferLeft"
                && keys.command(for: Shortcut(.right, .control)) == "cm_TransferRight")
        #expect(keys.command(for: Shortcut(.character("u"), .control)) == .exchangePanels)
        #expect(keys.command(for: Shortcut(.character("r"), .control)) == .reread)
        #expect(keys.command(for: Shortcut(.character("\\"), .control)) == .goToRoot)
        #expect(keys.conflicts.isEmpty)
        let inMenus = bench.kernel.menus.menus.flatMap(\.items).compactMap { $0 }
        #expect(
            inMenus.allSatisfy { commands[$0] != nil } && inMenus.contains("afm_GoDesktop")
                && inMenus.contains("cm_GoToNextDrive"))
        #expect(
            bench.kernel.toolbar.defaultLayout.compactMap { $0?.command } == [
                .goBack, .goForward, .goToParent, .reread
            ])
    }

    @Test func showsTheFolderUnderTheCursorInTheOtherPanel() {
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

    @Test func mirrorsThePathEitherWay() {
        commands.perform(.targetEqualsSource)
        #expect(right.model.directory.path == "/A")
        right.show(memory.url("/B"))
        commands.perform("afm_MatchTrg")
        #expect(left.model.directory.path == "/B")
    }

    @Test func goesToTheStandardPlaces() {
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
                && commands[CommandID(rawValue: "afm_GoVolumes")] != nil)
    }

    @Test func cyclesThroughTheVolumes() {
        commands.perform("cm_GoToNextDrive")
        #expect(left.model.directory == other.url("/"))
        commands.perform("cm_GoToNextDrive")
        #expect(left.model.directory == memory.url("/"))
        left.show(other.url("/data"))
        commands.perform("cm_GoToPreviousDrive")
        #expect(left.model.directory == memory.url("/"))
    }

    @Test func choosesTheNeighbourPlace() throws {
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
                == "Macintosh HD")
        #expect(
            NavigationPlugin.neighbourPlace(of: URL(fileURLWithPath: "/Users/x"), in: single, delta: -1)?.name
                == "Macintosh HD")
        #expect(NavigationPlugin.neighbourPlace(of: URL(fileURLWithPath: "/"), in: [places[2]], delta: 1) == nil)
        #expect(NavigationPlugin.neighbourPlace(of: URL(fileURLWithPath: "/x"), in: [], delta: 1) == nil)
    }

    @Test func goesToThePathOnTheClipboard() {
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
                && NavigationPlugin.path(fromClipboard: "'/a b'") == "/a b")
    }
}
