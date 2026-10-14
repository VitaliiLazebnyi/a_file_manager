import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@Suite struct LocalDisk {
    let local = LocalFileSystem()

    @Test func listsADirectory() throws {
        let box = try Sandbox()
        try box.file("a.txt", String(repeating: "a", count: 2_048))
        try box.folder("docs")
        try box.file(".hidden")
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: box.url("docs"))
        let visible = try local.list(box.root, showHidden: false)
        #expect(Set(visible.map(\.name)) == ["a.txt", "docs", "link"])
        #expect(try local.list(box.root, showHidden: true).count == 4)
        let file = try #require(visible.first { $0.name == "a.txt" })
        #expect(!file.isDirectory && file.size == 2_048)
        let link = try #require(visible.first { $0.name == "link" })
        #expect(link.isDirectory && link.isSymlink && !link.isRealDirectory)
        #expect(throws: (any Error).self) { try local.list(box.url("missing"), showHidden: false) }
        #expect(local.capabilities.contains([.write, .trash]))
        #expect(local.displayPath(box.url("docs")) == box.url("docs").path)
    }

    @Test func theBulkListingAgreesWithLookingAtEachEntry() throws {
        let box = try Sandbox()
        try box.file(
            "plain.txt", String(repeating: "p", count: 1_234), modified: Date(timeIntervalSince1970: 1_700_000_000))
        try box.file("script.sh", "#!/bin/sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: box.url("script.sh").path)
        try box.file(".dotfile", "h")
        try box.folder("folder/inner")
        try box.folder("Tool.app/Contents")
        try box.file("name with spaces and ünïcödé.md", "u")
        try FileManager.default.createSymbolicLink(
            at: box.url("link-to-folder"), withDestinationURL: box.url("folder"))
        try FileManager.default.createSymbolicLink(
            at: box.url("link-to-file"), withDestinationURL: box.url("plain.txt"))
        try FileManager.default.createSymbolicLink(at: box.url("broken-link"), withDestinationURL: box.url("nowhere"))
        try box.file("flagged.txt")
        #expect(chflags(box.url("flagged.txt").path, UInt32(UF_HIDDEN)) == 0)

        let listed = try local.list(box.root, showHidden: true)
        #expect(listed.count == 10)
        for item in listed {
            // The one-entry lookup asks the system about this entry alone; both must agree.
            let single = try #require(local.item(at: item.url))
            #expect(item == single, "\(item.name) differs")
        }
        let byName = Dictionary(uniqueKeysWithValues: listed.map { ($0.name, $0) })
        #expect(
            byName["plain.txt"]?.size == 1_234
                && byName["plain.txt"]?.modified == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(byName["script.sh"]?.permissions == 0o750)
        #expect(byName["Tool.app"]?.isPackage == true && byName["folder"]?.isPackage == false)
        #expect(byName["link-to-folder"]?.isDirectory == true && byName["link-to-file"]?.isDirectory == false)
        #expect(byName["broken-link"]?.isSymlink == true && byName["broken-link"]?.isDirectory == false)
        #expect(byName["flagged.txt"]?.isHidden == true && byName[".dotfile"]?.isHidden == true)
        #expect(
            Set(try local.list(box.root, showHidden: false).map(\.name))
                == [
                    "plain.txt", "script.sh", "folder", "Tool.app", "name with spaces and ünïcödé.md", "link-to-folder",
                    "link-to-file", "broken-link"
                ])
        #expect(try local.list(box.url("folder/inner"), showHidden: true).isEmpty)
    }

    @Test func aLargeFolderIsListedInPieces() throws {
        let box = try Sandbox()
        let count = 9_000
        for index in 0..<count { FileManager.default.createFile(atPath: box.url("f\(index).dat").path, contents: nil) }
        try box.file(".hidden")
        // The whole listing, examined in parallel, has every entry exactly once.
        let all = try local.list(box.root, showHidden: false)
        #expect(all.count == count && Set(all.map(\.name)).count == count)
        // Piece by piece, the same entries arrive in several batches.
        var batches: [Int] = []
        var names: Set<String> = []
        try local.list(box.root, showHidden: false) { items in
            batches.append(items.count)
            names.formUnion(items.map(\.name))
            return true
        }
        #expect(batches.count >= 3 && names.count == count)
        // Stopping early stops the reading.
        var received = 0
        try local.list(box.root, showHidden: true) { _ in
            received += 1
            return false
        }
        #expect(received == 1)
    }

    @Test func itemsParentsAndRoots() throws {
        let box = try Sandbox()
        try box.file("a.txt")
        #expect(local.item(at: box.url("a.txt"))?.name == "a.txt")
        #expect(local.item(at: box.url("missing")) == nil)
        #expect(local.parent(of: URL(fileURLWithPath: "/")) == nil)
        #expect(local.parent(of: URL(fileURLWithPath: "/usr/bin"))?.path == "/usr")
        #expect(local.root(of: box.root).path == "/")
    }

    @Test func readsSeeksAndWrites() throws {
        let box = try Sandbox()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = try local.write(box.url("new.txt"))
        try writer.write(Data("hello ".utf8))
        try writer.write(Data("world".utf8))
        try writer.close(attributes: FileAttributes(modified: stamp, permissions: 0o600))
        #expect(box.read("new.txt") == "hello world")
        #expect(local.item(at: box.url("new.txt"))?.modified == stamp)
        #expect(local.item(at: box.url("new.txt"))?.permissions == 0o600)
        let reader = try local.read(box.url("new.txt"))
        #expect(try reader.read(upToCount: 5) == Data("hello".utf8))
        #expect(try reader.read(upToCount: 100) == Data(" world".utf8))
        #expect(try reader.read(upToCount: 100) == nil)
        try reader.seek(to: 6)
        #expect(try reader.read(upToCount: 100) == Data("world".utf8))
        reader.close()
    }

    @Test func writingNeverOverwritesAnExistingFile() throws {
        let box = try Sandbox()
        try box.file("kept.txt", "precious")
        #expect(throws: FileSystemError.self) { try local.write(box.url("kept.txt")) }
        #expect(box.read("kept.txt") == "precious")
    }

    @Test func movesWithAndWithoutReplacing() throws {
        let box = try Sandbox()
        try box.file("a.txt", "a")
        try box.file("b.txt", "b")
        #expect(throws: FileSystemError.self) {
            try local.move(box.url("a.txt"), to: box.url("b.txt"), replacing: false)
        }
        #expect(box.read("a.txt") == "a" && box.read("b.txt") == "b")
        try local.move(box.url("a.txt"), to: box.url("b.txt"), replacing: true)
        #expect(box.read("b.txt") == "a" && !box.exists("a.txt"))
        try local.move(box.url("b.txt"), to: box.url("c.txt"), replacing: false)
        #expect(box.read("c.txt") == "a")
    }

    @Test func removesOneItemAndNeverATree() throws {
        let box = try Sandbox()
        try box.file("docs/inside.txt")
        try box.folder("empty")
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: box.url("docs"))
        #expect(throws: (any Error).self) { try local.remove(box.url("docs")) }
        #expect(box.exists("docs/inside.txt"))
        try local.remove(box.url("empty"))
        // A link is removed as a link; what it points to stays.
        try local.remove(box.url("link"))
        #expect(!box.exists("empty") && box.exists("docs/inside.txt"))
        try local.remove(box.url("docs/inside.txt"))
        try local.remove(box.url("docs"))
        #expect(!box.exists("docs"))
    }

    @Test func copyingNeverTouchesAnExistingDestination() throws {
        let box = try Sandbox()
        try box.file("a.txt", "a")
        try local.copy(box.url("a.txt"), to: box.url("b.txt")) { _ in true }
        #expect(box.read("b.txt") == "a")
        try box.file("c.txt", "precious")
        #expect(throws: FileSystemError.self) { try local.copy(box.url("a.txt"), to: box.url("c.txt")) { _ in true } }
        #expect(box.read("c.txt") == "precious")
    }

    @Test func offersPlacesAndVolumeInformation() {
        let places = local.settledPlaces()
        #expect(places.first?.kind == .home)
        #expect(places.contains { $0.kind == .internalDisk && $0.url.path == "/" })
        let volume = local.volume(of: URL(fileURLWithPath: "/"))
        #expect(volume?.name.isEmpty == false && (volume?.totalBytes ?? 0) > 0)
    }

    @Test func reportsChangesInWatchedFoldersOnly() async throws {
        let box = try Sandbox()
        try box.folder("watched/sub")
        try box.folder("other")
        let changes = AsyncStream<[URL]>.makeStream()
        let watcher = await MainActor.run { local.watch([box.url("watched")]) { changes.continuation.yield($0) } }
        // The stream is made in the background, and a change before it runs is not seen: the
        // watched folder is changed again and again until the first report arrives.
        let writer = Task {
            try box.file("other/ignored.txt")
            try box.file("watched/sub/ignored.txt")
            var number = 0
            while !Task.isCancelled {
                try box.file("watched/new\(number).txt")
                number += 1
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { writer.cancel() }

        // The report comes over the main queue, which the tests of the process share: in a
        // run under the thread sanitizer it was held for more than a minute by other tests,
        // and the report of a watcher that was working came after the 60 s this used to
        // wait. The limit only ends a wait for a report that never comes.
        let timeout = Task {
            try await Task.sleep(nanoseconds: 600_000_000_000)
            changes.continuation.finish()
        }
        var seen: [String] = []
        for await change in changes.stream {
            seen += change.map(\.path)
            break
        }
        timeout.cancel()
        withExtendedLifetime(watcher) {}
        #expect(seen == [box.url("watched").path])
    }
}
