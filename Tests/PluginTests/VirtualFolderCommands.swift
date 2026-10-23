import AFMContracts
import AFMKernel
import AppKit
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import TestSupport
import Testing

@testable import VirtualFoldersPlugin

/// The plugin's commands, its file list service and the file system as a panel uses them.
@MainActor
@Suite
internal struct VirtualFolderCommands {
    /// A two-level tree that records what it was asked to watch.
    ///
    /// Unchecked: its switches are set by the test before use, and it is used from one thread at a
    /// time.
    private final class WatchableFileSystem: FileSystemProvider, @unchecked Sendable {
        let scheme = "watched"
        let capabilities: FileSystemCapabilities = []
        private(set) var watched: [URL] = []
        private var onChange: (@MainActor @Sendable ([URL]) -> Void)?

        func url(_ path: String) -> URL {
            var components = URLComponents()
            components.scheme = scheme
            components.host = ""
            components.path = path
            guard let url = components.url else {
                preconditionFailure("\(path) is not a path")
            }
            return url
        }

        @MainActor
        func fire() { onChange?(watched) }

        func list(_ directory: URL, showHidden _: Bool) throws -> [FileItem] {
            switch directory.path {
            case "/top":
                return [FileItem(url: url("/top/sub"), name: "sub", kind: .directory)]

            case "/top/sub":
                return [FileItem(url: url("/top/sub/f.txt"), name: "f.txt")]

            default:
                throw FileSystemError.notSupported("Listing")
            }
        }

        func item(at url: URL) -> FileItem? {
            FileItem(url: url, name: url.lastPathComponent, kind: .init(isDirectory: url.pathExtension.isEmpty))
        }
        func parent(of directory: URL) -> URL? { directory.path == "/" ? nil : directory.deletingLastPathComponent() }
        func read(_: URL) throws -> any FileReader { throw FileSystemError.notSupported("Reading") }
        func createDirectory(at _: URL) throws { throw FileSystemError.notSupported("Writing") }
        func write(_: URL) throws -> any FileWriter { throw FileSystemError.notSupported("Writing") }
        func remove(_: URL) throws { throw FileSystemError.notSupported("Writing") }
        func move(_: URL, to _: URL, replacing _: Bool) throws {
            throw FileSystemError.notSupported("Writing")
        }
        func copy(_: URL, to _: URL, progress _: (Int64) -> Bool) throws {
            throw FileSystemError.notSupported("Writing")
        }

        func watch(
            _ directories: [URL],
            onChange: @escaping @MainActor @Sendable ([URL]) -> Void
        ) -> (any WatchToken)? {
            watched = directories
            self.onChange = onChange
            return self
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The tree the panels show: `/A` on the left, `/B` on the right.
    internal let memory = MemoryFileSystem()
    /// The plugin under test.
    internal let plugin = VirtualFoldersPlugin()
    /// The kernel and the panels, with the navigation and file operation plugins.
    internal let bench: TestBench

    /// The kernel's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The left panel, the source.
    internal var left: FakePanel { bench.left }
    /// The right panel.
    internal var right: FakePanel { bench.right }
    /// The file system the plugin registered when it started.
    internal var fileSystem: VirtualFileSystem {
        guard let started = plugin.fileSystem else {
            preconditionFailure("The bench starts the plugin")
        }
        return started
    }

    private let scratch = ScratchPasteboard()

    /// A bench with the plugins started and a small tree in memory.
    internal init() {
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/A/docs/deep/leaf.txt", "leaf")
        memory.addFile("/A/pics/cat.jpg", "meow")
        memory.addFile("/B/other.txt", "o")
        bench = TestBench(
            plugins: [
                plugin, NavigationPlugin(pasteboard: scratch.pasteboard, home: memory.url("/A")), FileOperationsPlugin()
            ],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// Starting registers the file system, the service, the keys, the menu, the button and the page.
    @Test
    internal func registersItsFileSystemServiceCommandsAndOptions() {
        #expect(bench.kernel.fileSystems.all.contains { $0.scheme == "vfolder" })
        #expect(bench.kernel.services.find((any FileListService).self) != nil)
        #expect(bench.kernel.keyBindings.command(for: Shortcut(.character("b"), .control)) == .branchView)
        #expect(
            bench.kernel.keyBindings.command(for: Shortcut(.character("b"), [.control, .shift])) == "cm_DirBranchSel"
        )
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(bench.kernel.menus.menus.first { $0.title == "Commands" }?.items.contains(.branchView) == true)
        #expect(bench.kernel.toolbar.symbol(for: .branchView) != nil)
        #expect(bench.kernel.preferences.pages.contains { $0.title == "Branch View" })
    }

    /// Branch View lists every file below the folder, and `[..]` goes back to the folder itself.
    @Test
    internal func branchViewShowsEveryFileBelowAndLeavesThroughTheParentRow() {
        commands.perform(.branchView)
        #expect(left.names == ["docs/deep/leaf.txt", "docs/in.txt", "one.txt", "pics/cat.jpg"])
        #expect(commands.isChecked(.branchView) && left.model.hasParentRow)
        #expect(bench.kernel.fileSystems.displayPath(left.model.directory) == "mem:/A (branch)")
        #expect(left.tabs.title(at: 0) == "A")
        #expect(left.model.items.allSatisfy { $0.url.scheme == "mem" })
        #expect(left.model.volume?.name == "Memory")
        // `[..]` and Backspace lead to the real directory; so does the root command.
        #expect(left.model.parentTarget?.location == memory.url("/A"))
        #expect(left.model.rootTarget?.location == memory.url("/A"))
        commands.perform(.goToParent)
        #expect(left.model.directory == memory.url("/A") && left.names == ["docs", "pics", "one.txt"])
        #expect(!commands.isChecked(.branchView))
    }

    /// The command again goes to the folder of the file under the cursor; its parameter switches on or off.
    @Test
    internal func leavingWithTheCommandGoesToTheFolderOfTheFileUnderTheCursor() {
        commands.perform(.branchView)
        left.moveCursor(toName: "docs/deep/leaf.txt")
        commands.perform(.branchView)
        #expect(left.model.directory.path == "/A/docs/deep" && left.model.cursorItem?.name == "leaf.txt")
        commands.perform(.branchView, .index(1))
        #expect(left.names == ["leaf.txt"] && commands.isChecked(.branchView))
        commands.perform(.branchView, .index(1))
        #expect(commands.isChecked(.branchView))
        left.model.moveCursor(to: 0)
        commands.perform(.branchView, .index(2))
        #expect(left.model.directory.path == "/A/docs/deep" && !commands.isChecked(.branchView))
        commands.perform(.branchView, .index(-1))
        #expect(!commands.isChecked(.branchView))
    }

    /// A selected branch lists the marked items only, and leaving it marks them again.
    @Test
    internal func selectedBranchShowsOnlyTheMarkedItemsAndRestoresTheSelection() {
        left.model.select(mask: "docs one.txt")
        commands.perform("cm_DirBranchSel")
        #expect(left.names == ["docs/deep/leaf.txt", "docs/in.txt", "one.txt"])
        #expect(bench.kernel.fileSystems.displayPath(left.model.directory).hasPrefix("mem:/A (selected branch "))
        left.model.moveCursor(to: 0)
        commands.perform("cm_DirBranchSel")
        #expect(left.model.directory == memory.url("/A") && left.model.selection == ["docs", "one.txt"])
        #expect(left.model.cursorItem?.name == "one.txt")
        // Without a selection the item under the cursor is the branch.
        left.model.clearSelection()
        left.moveCursor(toName: "pics")
        commands.perform("cm_DirBranchSel")
        #expect(left.names == ["pics/cat.jpg"])
    }

    /// The right-side command puts the right panel into branch view, whichever panel is the source.
    @Test
    internal func theSidedCommandsWorkOnTheirPanel() {
        commands.perform("cm_RightDirBranch")
        #expect(
            right.names == ["other.txt"] && VirtualLocation(right.model.directory) != nil
                && VirtualLocation(left.model.directory) == nil
        )
        #expect(commands.isChecked("cm_RightDirBranch") && !commands.isChecked("cm_LeftDirBranch"))
        right.model.moveCursor(to: 0)
        commands.perform("cm_RightDirBranch")
        #expect(right.model.directory == memory.url("/B"))
    }

    /// Deleting and making a folder in a branch view change the real files.
    @Test
    internal func operationsWorkOnTheRealFiles() {
        commands.perform(.branchView)
        left.moveCursor(toName: "docs/in.txt")
        bench.interaction.choiceAnswers = [0]
        commands.perform(.deleteDirectly)
        #expect(!memory.exists("/A/docs/in.txt") && memory.exists("/A/docs/deep/leaf.txt"))
        // The panel still shows the branch, without the deleted file.
        #expect(left.names == ["docs/deep/leaf.txt", "one.txt", "pics/cat.jpg"])
        // What is created in a branch view lands in the real directory.
        try? fileSystem.createDirectory(at: left.model.directory.appending(name: "new"))
        #expect(memory.exists("/A/new"))
        #expect(fileSystem.capabilities == memory.capabilities)
    }

    /// A shown file list names each file by its full path, keeps its real location, and can be typed back.
    @Test
    internal func aFileListKeepsRealLocationsAndFullPathsAsNames() throws {
        let service = try #require(bench.kernel.services.find((any FileListService).self))
        let files = [
            memory.url("/A/docs/in.txt"), memory.url("/B/other.txt"), memory.url("/A/gone.txt"),
            memory.url("/B/other.txt")
        ]
        service.show(files, title: "Search result", in: left)
        #expect(left.names == ["mem:/A/docs/in.txt", "mem:/B/other.txt"])
        #expect(left.model.items.map(\.url) == [memory.url("/A/docs/in.txt"), memory.url("/B/other.txt")])
        #expect(left.tabs.title(at: 0) == "Search result" && left.model.volume?.name == "Search result:")
        let shown = bench.kernel.fileSystems.displayPath(left.model.directory)
        #expect(shown.hasPrefix("Search result (list "))
        // What the path bar writes can be typed again.
        #expect(bench.kernel.fileSystems.location(from: shown, relativeTo: memory.url("/")) == left.model.directory)
        #expect(fileSystem.location(from: "mem:/A (branch)") == fileSystem.branch(of: memory.url("/A")))
        #expect(
            fileSystem.location(from: fileSystem.branch(of: memory.url("/A")).absoluteString)
                == fileSystem.branch(of: memory.url("/A"))
        )
        #expect(fileSystem.location(from: "nothing (list 999)") == nil && fileSystem.location(from: "plain") == nil)
        #expect(throws: (any Error).self) { try fileSystem.write(left.model.directory.appending(name: "x")) }
        // The command goes to the folder of the file under the cursor; `[..]` back to where the list was opened.
        left.moveCursor(toName: "mem:/B/other.txt")
        commands.perform(.branchView)
        #expect(left.model.directory == memory.url("/B") && left.model.cursorItem?.name == "other.txt")
        service.show(files, title: "Again", in: left)
        commands.perform(.goToParent)
        #expect(left.model.directory == memory.url("/B"))
    }

    /// A list from an earlier run is not shown, and the panel stays where it was.
    @Test
    internal func aForgottenListFailsWithoutHarm() {
        let stale = VirtualLocation.list(id: 4_711, title: "Old", origin: memory.url("/A")).url
        left.show(stale)
        #expect(left.model.directory == memory.url("/A") && left.failures.count == 1)
        #expect(fileSystem.item(at: stale) == nil && fileSystem.parent(of: stale) == memory.url("/A"))
        #expect(fileSystem.parent(of: memory.url("/A")) == nil)
    }

    /// Load File List shows the files a list file names and reports a list file that is missing.
    @Test
    internal func loadsAListFile() {
        memory.addFile("/A/found.lst", "\u{FEFF}mem:/A/one.txt\r\ndocs/in.txt\r\n\r\n  mem:/B/other.txt  \n")
        commands.perform("LOADLIST", .location(memory.url("/A/found.lst")))
        #expect(left.names == ["mem:/A/docs/in.txt", "mem:/A/one.txt", "mem:/B/other.txt"])
        #expect(left.tabs.title(at: 0) == "found" && bench.jobService.titles == ["Load file list"])
        bench.interaction.promptAnswers = [.text("mem:/A/missing.lst")]
        commands.perform("LOADLIST")
        #expect(bench.interaction.log.last == "inform: The list of files could not be loaded.")
        #expect(FileListFile.lines(in: Data([0xFF, 0xFE, 0x61, 0x00, 0x0A, 0x00, 0x62, 0x00])) == ["a", "b"])
    }

    /// Turning on "list the folders too" adds the folders to a branch view that is shown.
    @Test
    internal func optionsChangeWhatABranchLists() {
        commands.perform(.branchView)
        bench.kernel.settings.set(true, forKey: VirtualFoldersPlugin.listsFoldersKey)
        bench.kernel.preferences.pages.first { $0.title == "Branch View" }?.onChange()
        #expect(
            left.names == ["docs", "docs/deep", "pics", "docs/deep/leaf.txt", "docs/in.txt", "one.txt", "pics/cat.jpg"]
        )
    }

    /// Watching a branch or a list watches the real folders, and their reports come back for the view.
    @Test
    internal func watchingIsForwardedToTheRealFileSystem() async throws {
        let watched = WatchableFileSystem()
        let registry = FileSystemRegistry()
        registry.register(watched)
        let virtual = VirtualFileSystem(fileSystems: registry)
        let branch = virtual.branch(of: watched.url("/top"))
        _ = try virtual.list(branch, showHidden: false)
        var reported: [[URL]] = []
        let watcher = virtual.watch([branch]) { urls in reported.append(urls) }
        #expect(watcher != nil && Set(watched.watched.map(\.path)) == ["/top", "/top/sub"])
        watched.fire()
        // Reports reach the caller on the main thread: wait for the main queue.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(reported == [[branch]])
        let list = virtual.register(files: [watched.url("/top/sub/f.txt")], title: "L", origin: nil)
        let second = virtual.watch([list]) { _ in
            // Only the watching itself counts here.
        }
        #expect(second != nil && watched.watched.map(\.path) == ["/top/sub"])
        let unwatched = virtual.watch([watched.url("/top")]) { _ in
            // Only the watching itself counts here.
        }
        #expect(unwatched == nil)
    }
}
