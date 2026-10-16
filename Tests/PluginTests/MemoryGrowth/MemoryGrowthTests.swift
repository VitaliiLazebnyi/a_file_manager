import AFMKernel
import AppKit
import FileOperationsPlugin
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import ArchivesPlugin
@testable import NetworkPlugin
@testable import ViewerPlugin

/// Long loops of what a user does all day, which must not make the program hold more memory.
///
/// The longer the program runs, the more often it does these: panels and folders opened and
/// closed, jobs run, viewers and archives opened and closed, a server connected and disconnected.
/// See `MemoryGrowth` for how growth is measured; run with `Scripts/check.sh memory`.
@MainActor
@Suite(.serialized, .enabled(if: MemoryGrowth.isEnabled))
internal struct MemoryGrowthTests {
    /// How far the footprint may rise from the first measured round to the last: what the
    /// allocator keeps of freed memory in pieces it cannot hand back.
    private static let tolerance = 4 << 20

    /// Entries of the folder the panels show.
    private static let listLength = 20_000

    /// A folder of entries with names, sizes and dates that differ.
    private static func entries(_ count: Int) -> [FileItem] {
        (0..<count)
            .map { index in
                let name = index.isMultiple(of: 3) ? "report \(index).txt" : "image_\(index).jpg"
                return FileItem(
                    url: URL(fileURLWithPath: "/folder/\(name)"),
                    name: name,
                    kind: .init(isDirectory: index.isMultiple(of: 25)),
                    stat: .init(
                        size: Int64(index * 37 % 100_000),
                        modified: Date(timeIntervalSinceReferenceDate: Double(index % 1_000) * 60)
                    )
                )
            }
    }

    /// Records an issue when the footprints grew.
    private static func expectNoGrowth(_ footprints: [Int], perRound: Int) {
        if let growth = MemoryGrowth.growth(footprints, perRound: perRound, tolerance: tolerance) {
            Issue.record(Comment(rawValue: growth))
        }
    }

    /// Waits until `condition` holds, up to `Wait.ceiling`, looking every few milliseconds.
    private static func wait(until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Wait.ceiling)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    /// The measurement itself: a loop that keeps 256 KB of every run is caught, and one that
    /// keeps nothing is not.
    @Test
    internal func aLoopThatKeepsMemoryIsCaught() {
        var kept: [[UInt8]] = []
        let perRound = 20
        let growing = MemoryGrowth.footprints(perRound: perRound) {
            kept.append([UInt8](repeating: 1, count: 256 << 10))
        }
        let steady = MemoryGrowth.footprints(perRound: perRound) {
            _ = [UInt8](repeating: 1, count: 256 << 10).reduce(0, &+)
        }
        #expect(MemoryGrowth.growth(growing, perRound: perRound, tolerance: Self.tolerance) != nil)
        #expect(MemoryGrowth.growth(steady, perRound: perRound, tolerance: Self.tolerance) == nil)
        #expect(kept.count == perRound * (MemoryGrowth.rounds + 1))
    }

    /// A panel made for a long folder, sorted, filtered and marked, then let go.
    @Test
    internal func panelsOpenedAndClosed() {
        let order = ListOrder(key: .name)
        let directory = URL(fileURLWithPath: "/folder", isDirectory: true)
        let items = Sorter.sort(Self.entries(Self.listLength), by: order)
        let listing = Listing(directory: directory, items: items, parent: nil, root: URL(fileURLWithPath: "/"))
        let perRound = 20
        let footprints = MemoryGrowth.footprints(perRound: perRound) {
            let model = PanelModel(directory: directory, sort: order, showHidden: true)
            model.show(listing, presorted: order)
            model.setSort(ListOrder(key: .size, descending: true))
            model.setFilter(.mask("*.txt"))
            model.select(mask: "report 1*")
            model.selectAll()
            model.invertSelection()
            _ = model.operands()
            model.setFilter(nil)
        }
        Self.expectNoGrowth(footprints, perRound: perRound)
    }

    /// Folders on the disk read and shown in one panel, one after another.
    @Test
    internal func foldersOpenedAndClosed() throws {
        let box = try Sandbox()
        for folder in ["one", "two", "three"] {
            for index in 0..<500 {
                try box.file("\(folder)/file \(index).txt")
            }
        }
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        let model = PanelModel(directory: box.url("one"), sort: ListOrder(), showHidden: true)
        let perRound = 10
        let footprints = try MemoryGrowth.footprints(perRound: perRound) {
            for folder in ["one", "two", "three"] {
                let result = try PanelLoader.load(box.url(folder), showHidden: true, fileSystems: fileSystems)
                model.show(result.listing)
            }
        }
        Self.expectNoGrowth(footprints, perRound: perRound)
    }

    /// Files copied by a job and deleted by another, again and again.
    @Test
    internal func jobsRun() {
        let memory = MemoryFileSystem()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(memory)
        let sources = (0..<20).map { memory.addFile("/source/file \($0).txt", String(repeating: "x", count: 10_000)) }
        let target = memory.addDirectory("/target")
        let perRound = 20
        let footprints = MemoryGrowth.footprints(perRound: perRound) {
            let copied = FileJob(
                kind: .copy,
                sources: sources,
                target: TargetSpec(directory: target),
                fileSystems: fileSystems
            )
            .run()
            let copies = sources.map { target.appending(name: $0.lastPathComponent) }
            let deleted = FileJob(kind: .delete(toTrash: false), sources: copies, fileSystems: fileSystems).run()
            #expect(copied.failureCount == 0 && deleted.failureCount == 0)
        }
        Self.expectNoGrowth(footprints, perRound: perRound)
    }

    /// A ZIP archive opened, listed and read, and the archive let go.
    @Test
    internal func archivesOpenedAndClosed() throws {
        let box = try Sandbox()
        for index in 0..<300 {
            try box.file("content/entry \(index).txt", String(repeating: "\(index) ", count: 50))
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = box.root
        zip.arguments = ["-q", "-r", "archive.zip", "content"]
        try zip.run()
        zip.waitUntilExit()
        let archive = box.url("archive.zip")
        let perRound = 20
        let footprints = try MemoryGrowth.footprints(perRound: perRound) {
            let environment = ArchiveEnvironment()
            environment.flushDelay = nil
            let fileSystems = FileSystemRegistry()
            fileSystems.register(LocalFileSystem())
            let provider = ArchiveFileSystem(
                scheme: ArchiveURL.writableScheme,
                store: ArchiveStore(environment: environment)
            )
            fileSystems.register(provider)
            environment.fileSystems = { [weak fileSystems] in fileSystems }
            let folder = ArchiveURL.make(scheme: ArchiveURL.writableScheme, archive: archive, innerPath: "content")
            let items = try provider.list(folder, showHidden: true)
            let reader = try provider.read(folder.appending(name: "entry 7.txt"))
            _ = try reader.read(upToCount: 1_000)
            reader.close()
            #expect(items.count == 300)
        }
        Self.expectNoGrowth(footprints, perRound: perRound)
    }

    /// A Lister window opened on a file, shown and closed.
    @Test
    internal func viewersOpenedAndClosed() async throws {
        _ = NSApplication.shared
        let memory = MemoryFileSystem()
        let lines = (1...2_000).map { "Line \($0) of a text to be shown" }
        let file = memory.addFile("/A/text.txt", lines.joined(separator: "\n"))
        let plugin = ViewerPlugin(overlayHost: { _ in nil }, quickViewDelay: 0.01, showsWindows: false)
        let bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/A"))
        let perRound = 10
        let footprints = try await MemoryGrowth.footprints(perRound: perRound) {
            plugin.view(file)
            let controller = try #require(plugin.windows.last)
            #expect(await Self.wait { controller.pane.loaded != nil })
            controller.close()
            #expect(plugin.windows.isEmpty)
        }
        plugin.stop()
        _ = bench
        Self.expectNoGrowth(footprints, perRound: perRound)
    }

    /// A server connected to, listed and disconnected from.
    @Test
    internal func serverConnectedAndDisconnected() throws {
        let fixture = try FTPFixture()
        try fixture.box.file("srv/readme.txt", "hello")
        let perRound = 10
        let footprints = try MemoryGrowth.footprints(perRound: perRound) {
            let names = try fixture.names("/")
            #expect(names == ["readme.txt"])
            fixture.center.disconnectAll()
            #expect(fixture.settle())
        }
        Self.expectNoGrowth(footprints, perRound: perRound)
    }
}
