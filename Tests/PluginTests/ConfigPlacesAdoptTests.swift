import AFMContracts
import AFMKernel
@testable import ConfigurationPlugin
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
@testable import PlacesPlugin
import SelectionPlugin
import TestSupport
import Testing
@testable import VirtualFoldersPlugin

/// Waits for `condition` without a fixed sleep: it polls, with a generous limit.
private func waitFor(_ limit: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(limit)
    while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    return condition()
}

/// Attaches a disk image to a folder, so that a real mount point exists; nil where that is not possible.
private final class MountedImage {
    let mountPoint: URL
    private let image: URL

    init?(in box: Sandbox, at name: String) {
        image = box.url("\(name).dmg")
        mountPoint = box.url(name)
        guard (try? box.folder(name)) != nil,
              MountedImage.run(["create", "-size", "4m", "-fs", "HFS+", "-volname", "AFMTest", image.path]),
              MountedImage.run(["attach", image.path, "-nobrowse", "-mountpoint", mountPoint.path]) else { return nil }
    }

    deinit { _ = MountedImage.run(["detach", "-force", mountPoint.path]) }

    private static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

@Suite struct VirtualFoldersAdoption {
    let memory = MemoryFileSystem()
    let registry = FileSystemRegistry()
    let virtual: VirtualFileSystem

    init() {
        registry.register(LocalFileSystem())
        registry.register(memory)
        virtual = VirtualFileSystem(fileSystems: registry)
    }

    func names(_ url: URL) throws -> [String] {
        try virtual.list(url, showHidden: true).map(\.name).sorted()
    }

    @Test func eachLocationReportsWhatItsOwnFileSystemCanDo() throws {
        let box = try Sandbox()
        try box.file("L/a.txt")
        memory.addFile("/R/b.txt")
        memory.capabilitiesAt = { _ in [] }
        let local = virtual.capabilities(for: virtual.branch(of: box.url("L")))
        let readOnly = virtual.capabilities(for: virtual.branch(of: memory.url("/R")))
        #expect(local.contains(.write) && local.contains(.trash))
        #expect(readOnly == [])
        // The same holds for selected branches and lists, whatever was read last.
        let picked = virtual.registerPicked([memory.url("/R/b.txt")], in: memory.url("/R"))
        #expect(virtual.capabilities(for: picked) == [])
        let mixed = virtual.register(files: [box.url("L/a.txt"), memory.url("/R/b.txt")], title: "Found", origin: nil)
        #expect(virtual.capabilities(for: mixed) == [])
        let localList = virtual.register(files: [box.url("L/a.txt")], title: "Local", origin: nil)
        // (A list's files can be deleted and trashed where they lie; nothing can be made "in" a list.)
        #expect(virtual.capabilities(for: localList) == [.write, .trash, .removeOnly])
        _ = try names(virtual.branch(of: memory.url("/R")))
        #expect(virtual.capabilities(for: virtual.branch(of: box.url("L"))) == local)
        #expect(virtual.capabilities(for: URL(fileURLWithPath: "/tmp")) == virtual.capabilities)
    }

    @Test func aCancelledBranchWalkOfAStalledTreeEndsAndLeavesNothingBehind() throws {
        memory.addFile("/S/a/f.txt")
        memory.stallsListings = true
        let flag = CancellationFlag()
        let finished = DispatchSemaphore(value: 0)
        let branch = virtual.branch(of: memory.url("/S"))
        let virtual = self.virtual
        Thread.detachNewThread {
            _ = try? virtual.list(branch, showHidden: false, cancellation: flag) { _ in true }
            finished.signal()
        }
        #expect(waitFor { memory.listRequests(for: "/S") > 0 })
        flag.cancel()
        let ended = finished.wait(timeout: .now() + 60) == .success
        memory.releaseStalls()
        #expect(ended)
        // A walk that was given up is no branch: the same walk without a flag reads it all.
        #expect(try names(branch) == ["a/f.txt"])
    }

    @Test func aWalkWithAFlagThatIsNeverSetListsAsWithout() throws {
        memory.addFile("/W/a/f.txt")
        memory.addFile("/W/g.txt")
        let branch = virtual.branch(of: memory.url("/W"))
        let flagged = try virtual.list(branch, showHidden: false, cancellation: CancellationFlag()).map(\.name).sorted()
        let plain = try names(branch)
        #expect(flagged == ["a/f.txt", "g.txt"] && flagged == plain)
    }

    @Test func callsAreForwardedToTheRealFileSystem() throws {
        memory.capabilities = [.write, .append, .deferredWrites]
        memory.keepsMetadata = true
        memory.quarantineValue = Data("0083;5e;Safari;".utf8)
        memory.addFile("/F/one.txt", "hello")
        memory.addDirectory("/F/dir")
        memory.addDirectory("/G/copy")
        let branch = virtual.branch(of: memory.url("/F"))
        let flag = CancellationFlag()

        let reader = try virtual.read(VirtualLocation.branch(of: memory.url("/F/one.txt")).url, cancellation: flag)
        #expect(try reader.read(upToCount: 10) == Data("hello".utf8))
        reader.close()
        let writer = try virtual.write(VirtualLocation.branch(of: memory.url("/F/new.txt")).url, cancellation: flag)
        try writer.write(Data("abc".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(memory.contents("/F/new.txt") == "abc")
        let appender = try virtual.append(to: VirtualLocation.branch(of: memory.url("/F/new.txt")).url, at: 1, cancellation: flag)
        try appender.write(Data("Z".utf8))
        try appender.close(attributes: FileAttributes())
        #expect(memory.contents("/F/new.txt") == "aZ")

        try virtual.commit(branch, cancellation: flag)
        #expect(memory.commits == ["/F"])
        #expect(virtual.quarantine(of: branch) == memory.quarantineValue)
        try virtual.setQuarantine(Data("q".utf8), of: VirtualLocation.branch(of: memory.url("/F/dir")).url)
        #expect(memory.quarantineMarks["/F/dir"] == Data("q".utf8))

        // Both ends are translated; the real file system gets real locations.
        try virtual.copyMetadata(from: VirtualLocation.branch(of: memory.url("/F/dir")).url, to: VirtualLocation.branch(of: memory.url("/G/copy")).url)
        #expect(memory.metadataCopies.map(\.to) == ["/G/copy"] && memory.metadataCopies.first?.from.scheme == "mem")
        let list = virtual.register(files: [memory.url("/F/one.txt")], title: "Found", origin: nil)
        #expect(throws: FileSystemError.self) { try virtual.copyMetadata(from: list, to: VirtualLocation.branch(of: memory.url("/G/copy")).url) }

        #expect(virtual.item(at: VirtualLocation.branch(of: memory.url("/F/one.txt")).url, cancellation: flag)?.name == "one.txt")
        flag.cancel()
        #expect(virtual.item(at: VirtualLocation.branch(of: memory.url("/F/one.txt")).url, cancellation: flag) == nil)
        #expect(virtual.totalSize(of: branch, cancellation: CancellationFlag()) == 7)
    }

    @Test func sameNamedFilesOfAPickedViewHaveNamesOfTheirOwn() throws {
        memory.addFile("/X/a/same.txt", "1")
        memory.addFile("/X/b/same.txt", "22")
        memory.addFile("/X/c/other.txt", "3")
        let picked = virtual.registerPicked([memory.url("/X/a/same.txt"), memory.url("/X/b/same.txt"), memory.url("/X/c/other.txt")],
                                            in: memory.url("/X"))
        let items = try virtual.list(picked, showHidden: true)
        #expect(Set(items.map { Array($0.name.utf8) }).count == 3)
        #expect(items.filter { $0.name.hasSuffix("same.txt") }.count == 2 && items.contains { $0.name == "other.txt" })
        // Whatever the name says, the entry is the real file.
        #expect(Set(items.map(\.url.path)) == ["/X/a/same.txt", "/X/b/same.txt", "/X/c/other.txt"])
    }

    @Test func foldersOfAPickedViewKeepTheirContentsApart() throws {
        memory.addFile("/Y/p/dir/in.txt")
        memory.addFile("/Y/q/dir/in.txt")
        let picked = virtual.registerPicked([memory.url("/Y/p/dir"), memory.url("/Y/q/dir")], in: memory.url("/Y"))
        let items = try virtual.list(picked, showHidden: true)
        #expect(items.count == 2 && Set(items.map(\.name)).count == 2 && Set(items.map(\.url.path)) == ["/Y/p/dir/in.txt", "/Y/q/dir/in.txt"])
    }

    @Test func operationsOnAPickedViewActOnTheRealFiles() throws {
        let box = try Sandbox()
        try box.file("a/same.txt", "1")
        try box.file("b/same.txt", "2")
        let picked = virtual.registerPicked([box.url("a/same.txt"), box.url("b/same.txt")], in: box.root)
        let items = try virtual.list(picked, showHidden: true)
        let second = try #require(items.first { $0.url.path.hasSuffix("b/same.txt") })
        let local = try registry.provider(for: second.url)
        try local.move(second.url, to: box.url("b/renamed.txt"), replacing: false)
        let first = try #require(items.first { $0.url.path.hasSuffix("a/same.txt") })
        try local.copy(first.url, to: box.url("copy.txt"), progress: { _ in true })
        try local.remove(first.url)
        #expect(box.read("b/renamed.txt") == "2" && box.read("copy.txt") == "1" && !box.exists("a/same.txt"))
    }

    @Test func twoNamesThatDifferOnlyInNormalisationAreTwoFiles() throws {
        let (composed, decomposed) = ("caf\u{e9}.txt", "cafe\u{301}.txt")
        memory.addFile("/N/" + composed)
        memory.addFile("/N/" + decomposed)
        let urls = [memory.url("/N/" + composed), memory.url("/N/" + decomposed), memory.url("/N/" + composed)]
        let list = virtual.register(files: urls, title: "Twins", origin: nil)
        #expect(virtual.entries(of: list)?.count == 2)
        let picked = virtual.registerPicked(urls, in: memory.url("/N"))
        #expect(virtual.entries(of: picked)?.count == 2)
        let shown = try virtual.list(picked, showHidden: true)
        #expect(Set(shown.map { Array($0.name.utf8) }).count == 2)
    }

    @Test func aBranchWalkStaysOnItsVolume() throws {
        let box = try Sandbox()
        try box.file("plain/a.txt")
        guard let image = MountedImage(in: box, at: "mounted") else {
            // Shown as skipped, not as passed: nothing was checked.
            try Test.cancel("a disk image cannot be attached here (hdiutil)")
        }
        try Data("m".utf8).write(to: image.mountPoint.appendingPathComponent("inside.txt"))
        #expect(BranchWalker.isMountPoint(image.mountPoint.path) && !BranchWalker.isMountPoint(box.url("plain").path))
        #expect(try names(virtual.branch(of: box.root)) == ["mounted.dmg", "plain/a.txt"])
        // Started on the volume itself, the walk lists it.
        #expect(try names(virtual.branch(of: image.mountPoint)).contains("inside.txt"))
        #expect(BranchWalker.isMountPoint("/") && !BranchWalker.isMountPoint("/Users"))
    }
}

@Suite struct PlacesAdoption {
    @Test func levelsComeWithTheirNodesAndLinkLikeTheOldPath() throws {
        let box = try Sandbox()
        for path in ["a/b/c", "a/d", "e", "f/g", "a/b/h"] { try box.folder(path) }
        try box.file("a/file.txt")
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem(), batchSize: 2)
        var levels: [TreeScanner.Level] = []
        var offMain = true
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            scanner.run { batch in
                if Thread.isMainThread { offMain = false }
                levels += batch
            }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 60) == .success)
        #expect(offMain && levels.allSatisfy { $0.nodes.map(\.name) == $0.children })

        let linked = DirectoryTree(rootURL: box.root)
        for level in levels { linked.attach(level.nodes, ofPath: level.path) }
        let old = DirectoryTree(rootURL: box.root)
        for level in levels { old.setChildren(level.children, ofPath: level.path, sorted: level.isSorted) }
        #expect(linked.paths == old.paths && linked.paths == ["a", "a/b", "a/b/c", "a/b/h", "a/d", "e", "f", "f/g"])
        #expect(linked.count == old.count)
        for path in linked.paths {
            let (new, expected) = (try #require(linked.node(at: path)), try #require(old.node(at: path)))
            #expect(new.isScanned == expected.isScanned && new.depth == expected.depth && linked.url(of: new) == old.url(of: expected))
            #expect(new.parent === linked.node(at: (path as NSString).deletingLastPathComponent))
        }
        let cached = DirectoryTree(rootURL: box.root, paths: linked.paths)
        #expect(cached.paths == linked.paths)
    }

    @Test func aWideFolderIsLinkedInBoundedTurns() {
        let names = (0..<25).map { "folder\($0)" }
        let nodes = DirectoryTree.makeNodes(names, sorted: false)
        let tree = DirectoryTree(rootURL: URL(fileURLWithPath: "/V"))
        var next = 0
        var turns = 0
        while next < nodes.count {
            let before = next
            next = tree.attach(nodes, ofPath: "", from: before, limit: 10)
            #expect(next - before <= 10)
            #expect(tree.root.isScanned == (next == nodes.count))
            turns += 1
        }
        #expect(turns == 3 && tree.count == 25)
        let whole = DirectoryTree(rootURL: URL(fileURLWithPath: "/V"))
        whole.setChildren(names, ofPath: "")
        #expect(tree.paths == whole.paths && zip(tree.root.children, whole.root.children).allSatisfy { $0.name == $1.name && $0.indexInParent == $1.indexInParent })
        // A folder that was read by someone else in between is left alone.
        let other = DirectoryTree(rootURL: URL(fileURLWithPath: "/V"))
        other.attach(nodes, ofPath: "", from: 0, limit: 10)
        other.setChildren(["x"], ofPath: "")
        other.attach(nodes, ofPath: "", from: 10, limit: 10)
        #expect(other.paths == ["x"])
    }

    @Test func attachingToAKnownFolderKeepsWhatIsBelowIt() {
        let tree = DirectoryTree(rootURL: URL(fileURLWithPath: "/V"), paths: ["a", "a/deep", "b"])
        tree.attach(DirectoryTree.makeNodes(["a", "c"], sorted: true), ofPath: "")
        #expect(tree.paths == ["a", "a/deep", "c"] && tree.count == 3 && tree.node(at: "c")?.parent === tree.root)
    }

    @Test func aScanDoesNotEnterAMountedVolume() throws {
        let box = try Sandbox()
        try box.folder("plain/sub")
        guard let image = MountedImage(in: box, at: "mounted") else {
            // Shown as skipped, not as passed: nothing was checked.
            try Test.cancel("a disk image cannot be attached here (hdiutil)")
        }
        try FileManager.default.createDirectory(at: image.mountPoint.appendingPathComponent("inside"), withIntermediateDirectories: true)
        let scanner = TreeScanner(root: box.root, provider: LocalFileSystem())
        #expect(scanner.run { _ in })
        #expect(scanner.paths.contains("mounted") && !scanner.paths.contains("mounted/inside"))
        #expect(scanner.unscanned == ["mounted"] && scanner.paths.contains("plain/sub"))
        // The tree of the volume itself is read.
        let own = TreeScanner(root: image.mountPoint, provider: LocalFileSystem())
        #expect(own.run { _ in } && own.paths == ["inside"] && own.unscanned.isEmpty)
    }
}

@MainActor @Suite struct ConfigurationAdoption {
    let memory = MemoryFileSystem()
    let box: Sandbox

    init() throws { box = try Sandbox() }

    @Test func aMarkedNameIsNotMarkedForItsNormalisationTwin() throws {
        let (composed, decomposed) = ("caf\u{e9}.txt", "cafe\u{301}.txt")
        memory.addFile("/A/" + composed)
        memory.addFile("/A/" + decomposed)
        memory.addDirectory("/B")
        let plugin = ConfigurationPlugin(launchesApplications: false, background: nil, listFolder: box.url("lists"), settingsKeys: { [] })
        let bench = TestBench(plugins: [NavigationPlugin(), SelectionPlugin(), plugin], fileSystems: [LocalFileSystem(), memory],
                              left: memory.url("/A"), right: memory.url("/B"))
        bench.left.model.setSelected(true, names: [decomposed])
        plugin.center!.save(UserCommand(name: "em_marked", title: "", action: CommandAction(command: "echo", parameters: "%S")))
        bench.commands.perform("em_marked")
        let line = Array((plugin.launched.first ?? "").utf8)
        func contains(_ text: String) -> Bool {
            let needle = Array(text.utf8)
            return line.indices.contains { line[$0...].starts(with: needle) }
        }
        #expect(contains("cafe\u{301}.txt") && !contains("caf\u{e9}.txt"))
    }

    @Test func aStartMenuEntryInAChainIsWaitedFor() async {
        _ = try? box.folder("A")
        _ = try? box.folder("B")
        let plugin = ConfigurationPlugin(launchesApplications: true, background: nil, listFolder: box.url("lists"), settingsKeys: { [] })
        let bench = TestBench(plugins: [NavigationPlugin(), SelectionPlugin(), plugin], fileSystems: [LocalFileSystem()],
                              left: box.url("A"), right: box.url("B"))
        let center = plugin.center!
        let marker = box.url("marker").path
        var draft = center.startMenuDraft()
        draft.insert(StartMenuDraft.Row(entry: StartMenuEntry(title: "Build", action: CommandAction(command: "sleep 0.3; touch '\(marker)'"))), after: nil)
        center.commit(draft)
        var existed: Bool?
        bench.commands.register(Command("cm_ConfigProbe", "Probe")) { existed = FileManager.default.fileExists(atPath: marker) }
        center.save(UserCommand(name: "em_chain", title: "", action: CommandAction(command: "cm_UserMenu1, cm_ConfigProbe")))
        bench.commands.perform("em_chain")
        let deadline = Date().addingTimeInterval(60)
        while existed == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(existed == true)
    }
}
