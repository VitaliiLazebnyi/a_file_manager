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

@Suite struct VirtualLocations {
    @Test func aBranchLocationCarriesItsRealDirectory() throws {
        let real = URL(fileURLWithPath: "/Users/x/My Files/dir")
        let url = VirtualLocation.branch(of: real).url
        #expect(url.scheme == "vfolder" && url.lastPathComponent == "dir" && url.path == "/Users/x/My Files/dir")
        #expect(VirtualLocation(url) == .branch(of: real))
        #expect(VirtualLocation(url.standardized) == .branch(of: real))
        #expect(VirtualLocation(try #require(URL(string: url.absoluteString))) == .branch(of: real))
    }

    @Test func otherFileSystemsHostsAndPortsSurvive() throws {
        let memory = MemoryFileSystem()
        #expect(
            VirtualLocation(VirtualLocation.branch(of: memory.url("/A/docs")).url) == .branch(of: memory.url("/A/docs"))
        )
        let server = try #require(URL(string: "sftp://someone@files.example.org:2222/srv/www/a%20b"))
        let back = VirtualLocation(VirtualLocation.picked(id: 12, in: server).url)
        guard case .picked(12, let real)? = back else {
            Issue.record("not a picked branch: \(String(describing: back))")
            return
        }
        #expect(real.absoluteString == server.absoluteString)
        // A long prefix is cut into host labels of a legal length.
        let long = try #require(URL(string: "sftp://\(String(repeating: "u", count: 70))@host.example.org/x"))
        let host = try #require(VirtualLocation.branch(of: long).url.host)
        #expect(host.split(separator: ".").allSatisfy { $0.count <= 63 })
        #expect(
            VirtualLocation(VirtualLocation.branch(of: long).url)?.realDirectory?.absoluteString == long.absoluteString)
    }

    @Test func aListLocationKnowsItsTitleAndWhereItCameFrom() {
        let origin = URL(fileURLWithPath: "/Users/x")
        let url = VirtualLocation.list(id: 7, title: "Search result", origin: origin).url
        #expect(url.lastPathComponent == "Search result")
        #expect(VirtualLocation(url) == .list(id: 7, title: "Search result", origin: origin))
        let rootless = VirtualLocation.list(id: 8, title: "Found", origin: nil)
        #expect(VirtualLocation(rootless.url) == rootless && rootless.realDirectory == nil)
        let atRoot = VirtualLocation.list(id: 9, title: "Found", origin: URL(fileURLWithPath: "/"))
        #expect(VirtualLocation(atRoot.url)?.realDirectory?.path == "/")
        #expect(VirtualLocation.pathComponent("a/b") == "a:b" && VirtualLocation.pathComponent(" ") == "List")
    }

    @Test func foreignAndBrokenLocationsAreNotVirtual() throws {
        #expect(VirtualLocation(URL(fileURLWithPath: "/tmp")) == nil)
        #expect(VirtualLocation(try #require(URL(string: "vfolder://nonsense/x"))) == nil)
        #expect(VirtualLocation(try #require(URL(string: "vfolder://pick.hzz/x"))) == nil)
        #expect(VirtualLocation(try #require(URL(string: "vfolder://list/x"))) == nil)
    }
}

/// The walk reads many directories at once: this suite is the one to run with the thread sanitizer.
@Suite struct BranchWalking {
    let fileSystems = FileSystemRegistry()
    let memory = MemoryFileSystem()

    init() {
        fileSystems.register(LocalFileSystem())
        fileSystems.register(memory)
    }

    func names(_ starts: [BranchWalker.Start], _ walker: BranchWalker) throws -> [String] {
        var names: [String] = []
        try walker.walk(starts) { batch in
            names += batch.map(\.name)
            return true
        }
        return names.sorted()
    }

    @Test func listsEveryFileBelowWithItsRelativePathAndRealLocation() throws {
        memory.addFile("/A/one.txt")
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/A/docs/deep/er/leaf.txt")
        memory.addFile("/A/.git/config")
        memory.addDirectory("/A/empty")
        let walker = BranchWalker(fileSystems: fileSystems, showHidden: false)
        var items: [FileItem] = []
        let visited = try walker.walk([BranchWalker.Start(memory.url("/A"))]) { batch in
            items += batch
            return true
        }
        #expect(items.map(\.name).sorted() == ["docs/deep/er/leaf.txt", "docs/in.txt", "one.txt"])
        #expect(items.first { $0.name == "docs/in.txt" }?.url == memory.url("/A/docs/in.txt"))
        #expect(items.first { $0.name == "docs/in.txt" }?.size == 6)
        #expect(Set(visited.map(\.path)) == ["/A", "/A/docs", "/A/docs/deep", "/A/docs/deep/er", "/A/empty"])
        #expect(
            try names(
                [BranchWalker.Start(memory.url("/A"))], BranchWalker(fileSystems: fileSystems, showHidden: true)
            ).contains(".git/config"))
        let withFolders = try names(
            [BranchWalker.Start(memory.url("/A"))],
            BranchWalker(fileSystems: fileSystems, showHidden: false, listsFolders: true))
        #expect(
            withFolders == [
                "docs", "docs/deep", "docs/deep/er", "docs/deep/er/leaf.txt", "docs/in.txt", "empty", "one.txt"
            ])
    }

    @Test func aWideTreeIsReadCompletelyOnAllCores() throws {
        var expected: [String] = []
        for folder in 0..<300 {
            for file in 0..<3 {
                memory.addFile("/wide/d\(folder)/sub/f\(file).txt")
                expected.append("d\(folder)/sub/f\(file).txt")
            }
        }
        var batches = 0
        var names: [String] = []
        try BranchWalker(fileSystems: fileSystems, showHidden: false).walk([BranchWalker.Start(memory.url("/wide"))]) {
            batch in
            batches += 1
            names += batch.map(\.name)
            return true
        }
        #expect(names.sorted() == expected.sorted())
        #expect(Set(names).count == names.count && batches > 1)
    }

    @Test func stopsWhenNoMoreIsWantedAndSkipsWhatCannotBeRead() throws {
        for folder in 0..<200 { memory.addFile("/many/d\(folder)/f.txt") }
        var received = 0
        try BranchWalker(fileSystems: fileSystems, showHidden: false).walk([BranchWalker.Start(memory.url("/many"))]) {
            batch in
            received += batch.count
            return false
        }
        #expect(received > 0 && received <= BranchWalker.directoriesPerBatch)

        memory.addFile("/part/ok/a.txt")
        memory.addFile("/part/locked/b.txt")
        memory.unreadable = ["/part/locked"]
        let walker = BranchWalker(fileSystems: fileSystems, showHidden: false)
        #expect(try names([BranchWalker.Start(memory.url("/part"))], walker) == ["ok/a.txt"])
        memory.unreadable = ["/part"]
        #expect(try names([BranchWalker.Start(memory.url("/part"))], walker).isEmpty)
        #expect(throws: (any Error).self) {
            try walker.walk([BranchWalker.Start(memory.url("/part"))], mustRead: true) { _ in true }
        }
    }

    @Test func linksAreListedNotFollowedAndPackagesStayWhole() throws {
        let box = try Sandbox()
        try box.file("real/a.txt")
        try box.file("Tool.app/Contents/Info.plist")
        try FileManager.default.createSymbolicLink(at: box.url("loop"), withDestinationURL: box.root)
        let walker = BranchWalker(fileSystems: fileSystems, showHidden: false)
        #expect(try names([BranchWalker.Start(box.root)], walker) == ["Tool.app", "loop", "real/a.txt"])
        var entering = walker
        entering.entersPackages = true
        #expect(
            try names([BranchWalker.Start(box.root)], entering) == [
                "Tool.app/Contents/Info.plist", "loop", "real/a.txt"
            ])
    }

    @Test func manyWalksAtOnceShareTheProvidersSafely() {
        for folder in 0..<40 { memory.addFile("/shared/d\(folder)/x/f.txt") }
        let virtual = VirtualFileSystem(fileSystems: fileSystems)
        let counts = Parallel.map(Array(0..<8)) { index -> Int in
            if index % 2 == 0 { virtual.options = VirtualFileSystem.Options(listsFolders: false) }
            return ((try? virtual.list(virtual.branch(of: memory.url("/shared")), showHidden: false)) ?? []).count
        }
        #expect(counts == Array(repeating: 40, count: 8))
    }
}

@MainActor @Suite struct VirtualFolderCommands {
    let memory = MemoryFileSystem()
    let plugin = VirtualFoldersPlugin()
    let bench: TestBench

    var commands: CommandRegistry { bench.commands }
    var left: FakePanel { bench.left }
    var right: FakePanel { bench.right }
    var fileSystem: VirtualFileSystem { plugin.fileSystem! }

    private let scratch = ScratchPasteboard()

    init() {
        memory.addFile("/A/one.txt", "1")
        memory.addFile("/A/docs/in.txt", "inside")
        memory.addFile("/A/docs/deep/leaf.txt", "leaf")
        memory.addFile("/A/pics/cat.jpg", "meow")
        memory.addFile("/B/other.txt", "o")
        bench = TestBench(
            plugins: [
                plugin, NavigationPlugin(pasteboard: scratch.pasteboard, home: memory.url("/A")), FileOperationsPlugin()
            ],
            fileSystems: [LocalFileSystem(), memory], left: memory.url("/A"), right: memory.url("/B"))
    }

    @Test func registersItsFileSystemServiceCommandsAndOptions() {
        #expect(bench.kernel.fileSystems.all.contains { $0.scheme == "vfolder" })
        #expect(bench.kernel.services.find((any FileListService).self) != nil)
        #expect(bench.kernel.keyBindings.command(for: Shortcut(.character("b"), .control)) == .branchView)
        #expect(
            bench.kernel.keyBindings.command(for: Shortcut(.character("b"), [.control, .shift])) == "cm_DirBranchSel")
        #expect(bench.kernel.keyBindings.conflicts.isEmpty)
        #expect(bench.kernel.menus.menus.first { $0.title == "Commands" }?.items.contains(.branchView) == true)
        #expect(bench.kernel.toolbar.symbol(for: .branchView) != nil)
        #expect(bench.kernel.preferences.pages.contains { $0.title == "Branch View" })
    }

    @Test func branchViewShowsEveryFileBelowAndLeavesThroughTheParentRow() {
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

    @Test func leavingWithTheCommandGoesToTheFolderOfTheFileUnderTheCursor() {
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

    @Test func selectedBranchShowsOnlyTheMarkedItemsAndRestoresTheSelection() {
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

    @Test func theSidedCommandsWorkOnTheirPanel() {
        commands.perform("cm_RightDirBranch")
        #expect(
            right.names == ["other.txt"] && VirtualLocation(right.model.directory) != nil
                && VirtualLocation(left.model.directory) == nil)
        #expect(commands.isChecked("cm_RightDirBranch") && !commands.isChecked("cm_LeftDirBranch"))
        right.model.moveCursor(to: 0)
        commands.perform("cm_RightDirBranch")
        #expect(right.model.directory == memory.url("/B"))
    }

    @Test func operationsWorkOnTheRealFiles() {
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

    @Test func aFileListKeepsRealLocationsAndFullPathsAsNames() throws {
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
                == fileSystem.branch(of: memory.url("/A")))
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

    @Test func aForgottenListFailsWithoutHarm() {
        let stale = VirtualLocation.list(id: 4_711, title: "Old", origin: memory.url("/A")).url
        left.show(stale)
        #expect(left.model.directory == memory.url("/A") && left.failures.count == 1)
        #expect(fileSystem.item(at: stale) == nil && fileSystem.parent(of: stale) == memory.url("/A"))
        #expect(fileSystem.parent(of: memory.url("/A")) == nil)
    }

    @Test func loadsAListFile() {
        memory.addFile("/A/found.lst", "\u{FEFF}mem:/A/one.txt\r\ndocs/in.txt\r\n\r\n  mem:/B/other.txt  \n")
        commands.perform("LOADLIST", .location(memory.url("/A/found.lst")))
        #expect(left.names == ["mem:/A/docs/in.txt", "mem:/A/one.txt", "mem:/B/other.txt"])
        #expect(left.tabs.title(at: 0) == "found" && bench.jobService.titles == ["Load file list"])
        bench.interaction.promptAnswers = [.text("mem:/A/missing.lst")]
        commands.perform("LOADLIST")
        #expect(bench.interaction.log.last == "inform: The list of files could not be loaded.")
        #expect(FileListFile.lines(in: Data([0xFF, 0xFE, 0x61, 0x00, 0x0A, 0x00, 0x62, 0x00])) == ["a", "b"])
    }

    @Test func optionsChangeWhatABranchLists() {
        commands.perform(.branchView)
        bench.kernel.settings.set(true, forKey: VirtualFoldersPlugin.listsFoldersKey)
        bench.kernel.preferences.pages.first { $0.title == "Branch View" }?.onChange()
        #expect(
            left.names == ["docs", "docs/deep", "pics", "docs/deep/leaf.txt", "docs/in.txt", "one.txt", "pics/cat.jpg"])
    }

    @Test func watchingIsForwardedToTheRealFileSystem() async throws {
        let watched = WatchableFileSystem()
        let registry = FileSystemRegistry()
        registry.register(watched)
        let virtual = VirtualFileSystem(fileSystems: registry)
        let branch = virtual.branch(of: watched.url("/top"))
        _ = try virtual.list(branch, showHidden: false)
        var reported: [[URL]] = []
        let watcher = virtual.watch([branch]) { reported.append($0) }
        #expect(watcher != nil && Set(watched.watched.map(\.path)) == ["/top", "/top/sub"])
        watched.fire()
        // Reports reach the caller on the main thread: wait for the main queue.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(reported == [[branch]])
        let list = virtual.register(files: [watched.url("/top/sub/f.txt")], title: "L", origin: nil)
        let second = virtual.watch([list]) { _ in }
        #expect(second != nil && watched.watched.map(\.path) == ["/top/sub"])
        #expect(virtual.watch([watched.url("/top")]) { _ in } == nil)
    }
}

/// A two-level tree that records what it was asked to watch.
/// Unchecked: its switches are set by the test before use, and it is used from one thread at a time.
private final class WatchableFileSystem: FileSystemProvider, @unchecked Sendable {
    let scheme = "watched"
    let capabilities: FileSystemCapabilities = []
    private(set) var watched: [URL] = []
    private var onChange: (@MainActor @Sendable ([URL]) -> Void)?

    func url(_ path: String) -> URL { URL(string: "watched://" + path)! }
    @MainActor func fire() { onChange?(watched) }

    func list(_ directory: URL, showHidden _: Bool) throws -> [FileItem] {
        switch directory.path {
        case "/top": return [FileItem(url: url("/top/sub"), name: "sub", isDirectory: true)]
        case "/top/sub": return [FileItem(url: url("/top/sub/f.txt"), name: "f.txt", isDirectory: false)]
        default: throw FileSystemError.notSupported("Listing")
        }
    }

    func item(at url: URL) -> FileItem? {
        FileItem(url: url, name: url.lastPathComponent, isDirectory: url.pathExtension.isEmpty)
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

    func watch(_ directories: [URL], onChange: @escaping @MainActor @Sendable ([URL]) -> Void) -> (any WatchToken)? {
        watched = directories
        self.onChange = onChange
        return self
    }
}
