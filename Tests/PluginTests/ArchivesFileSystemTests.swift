import AFMKernel
@testable import ArchivesPlugin
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// The archive file systems driven as panels, jobs and searches drive any file system.
@Suite struct ArchiveFileSystems {
    let bench: ArchiveBench
    var box: Sandbox { bench.box }

    init() throws {
        bench = try ArchiveBench()
    }

    /// A ZIP made by the system's zip from the standard tree.
    func makeZip(_ name: String = "tree.zip") throws -> URL {
        try bench.makeTree()
        #expect(runTool("/usr/bin/zip", ["-qr", name, "tree"], in: box.root).status == 0)
        return box.url(name)
    }

    func write(_ text: String, to url: URL, modified: Date? = nil) throws {
        let writer = try bench.fileSystems.provider(for: url).write(url)
        try writer.write(Data(text.utf8))
        try writer.close(attributes: FileAttributes(modified: modified, permissions: 0o600))
    }

    // MARK: Locations

    @Test func urlsCarryTheArchiveAndThePathInside() throws {
        let archive = URL(fileURLWithPath: "/Users/me/my photos.zip")
        let root = ArchiveURL.make(scheme: "zip", archive: archive)
        #expect(root.scheme == "zip" && root.path == "/Users/me/my photos.zip" && root.lastPathComponent == "my photos.zip")
        let inner = root.appending(name: "2026").appending(name: "ü #1?.jpg")
        #expect(ArchiveURL.parse(inner) == .inside(ArchiveLocation(archive: archive, innerPath: "2026/ü #1?.jpg")))
        #expect(ArchiveURL.parse(root) == .inside(ArchiveLocation(archive: archive, innerPath: "")))
        #expect(ArchiveURL.parse(inner.deletingLastPathComponent()) == .inside(ArchiveLocation(archive: archive, innerPath: "2026")))
        #expect(inner.isInside(root) && inner.standardized == inner)
        #expect(ArchiveURL.make(scheme: "zip", archive: archive, innerPath: "2026/ü #1?.jpg").isSameLocation(as: inner))

        // A path that does not run through the archive is a place on the archive's own file system.
        var components = try #require(URLComponents(url: root, resolvingAgainstBaseURL: false))
        components.path = "/Users/me/Documents/notes.txt"
        let elsewhere = try #require(components.url)
        #expect(ArchiveURL.parse(elsewhere) == .outside(URL(fileURLWithPath: "/Users/me/Documents/notes.txt")))
        #expect(ArchiveURL.resolved(elsewhere).isFileURL && ArchiveURL.resolved(inner) == inner)
        #expect(ArchiveURL.parse(archive) == nil && URL(string: "zip://nonsense/a/b").flatMap(ArchiveURL.parse) == nil)

        // Archives on other file systems, and archives inside archives.
        let remote = try #require(URL(string: "ftp://user@server.example:2121/pub/a%20b/data.tar.gz"))
        let onServer = ArchiveURL.make(scheme: "archive", archive: remote, innerPath: "x/y")
        #expect(ArchiveURL.parse(onServer) == .inside(ArchiveLocation(archive: remote, innerPath: "x/y")))
        let nested = ArchiveURL.make(scheme: "zip", archive: inner.deletingLastPathComponent().appending(name: "inner.zip"), innerPath: "deep/file")
        guard case .inside(let location)? = ArchiveURL.parse(nested) else {
            Issue.record("not inside")
            return
        }
        #expect(location.innerPath == "deep/file" && location.archive.isSameLocation(as: root.appending(name: "2026").appending(name: "inner.zip")))
        #expect(ArchiveURL.location(of: location.archive)?.archive == archive)
        #expect(nested.path == "/Users/me/my photos.zip/2026/inner.zip/deep/file")
    }

    @MainActor @Test func leavingAnArchiveLeadsToTheFolderThatHoldsIt() throws {
        let archive = try makeZip()
        let deep = bench.inside(archive, "tree/sub/deep")
        #expect(bench.zip.parent(of: deep) == bench.inside(archive, "tree/sub"))
        #expect(bench.zip.parent(of: bench.inside(archive, "tree")) == bench.inside(archive))
        // Above the archive's top folder is the folder on disk, which is not this file system's:
        // there the climb ends.
        let above = try #require(bench.zip.parent(of: bench.inside(archive)))
        #expect(above.isFileURL && above.isSameLocation(as: box.root) && bench.zip.parent(of: above) == nil)
        #expect(bench.zip.root(of: deep).isSameLocation(as: box.root))
        #expect(bench.readOnly.parent(of: deep) == nil)

        // The panel loader finds the surroundings the same way, and a member's location leads
        // to its folder with the cursor on it.
        let loaded = try PanelLoader.load(bench.inside(archive, "tree/sub/random.bin"), showHidden: false, fileSystems: bench.fileSystems)
        #expect(loaded.listing.directory == bench.inside(archive, "tree/sub") && loaded.focus == "random.bin")
        #expect(loaded.listing.items.map(\.name).sorted() == ["deep", "random.bin"])
        let model = PanelModel(directory: box.root)
        model.show(try PanelLoader.load(bench.inside(archive), showHidden: false, fileSystems: bench.fileSystems).listing)
        #expect(model.parentTarget?.location.isSameLocation(as: box.root) == true && model.parentTarget?.focus == "tree.zip")
        #expect(model.rootTarget?.focus == "tree.zip")
    }

    @Test func pathsAreShownAndReadLikeFolders() throws {
        let archive = try makeZip()
        let inner = bench.inside(archive, "tree/sub")
        let shown = bench.fileSystems.displayPath(inner)
        #expect(shown == archive.path + "/tree/sub")
        // What is shown can be typed back, from anywhere.
        #expect(bench.fileSystems.location(from: shown, relativeTo: bench.memory.url("/")) == inner)
        #expect(bench.fileSystems.location(from: archive.path, relativeTo: box.root) == bench.inside(archive))
        #expect(bench.fileSystems.location(from: archive.path + "/tree/sub/", relativeTo: box.root) == inner)
        #expect(bench.fileSystems.location(from: inner.absoluteString, relativeTo: box.root) == inner)
        // A folder that merely ends like an archive stays a folder, and so does a missing file.
        try box.folder("folder.zip/x")
        #expect(bench.fileSystems.location(from: box.url("folder.zip/x").path, relativeTo: box.root).isFileURL)
        #expect(bench.fileSystems.location(from: box.url("missing.zip").path, relativeTo: box.root).isFileURL)
        // Formats that cannot be changed get the read-only file system.
        try bench.pack([box.url("tree")], to: box.url("tree.tgz")) { $0.format = .compressedTar(.gzip) }
        let readOnly = bench.fileSystems.location(from: box.url("tree.tgz").path + "/tree", relativeTo: box.root)
        #expect(try readOnly.scheme == ArchiveURL.readOnlyScheme && bench.names(readOnly).count == 5)
        #expect(bench.zip.capabilities == [.write, .deferredWrites] && bench.readOnly.capabilities == [])

        // A plain path typed while inside an archive means the disk.
        let typed = bench.fileSystems.location(from: box.url("tree/readme.txt").path, relativeTo: inner)
        #expect(typed.isFileURL && typed.path == box.url("tree/readme.txt").path)
        #expect(bench.zip.volume(of: inner)?.name == "tree.zip")
    }

    // MARK: Changing a ZIP

    @Test func aZipIsChangedInPlace() throws {
        let archive = try makeZip()
        let root = bench.inside(archive)
        let tree = root.appending(name: "tree")
        let before = FileSignature.of(archive.path)
        let stamp = Date(timeIntervalSince1970: 1_650_000_000)

        // New folder, with the folders above it.
        try bench.zip.createDirectory(at: tree.appending(name: "new").appending(name: "nested"))
        try bench.zip.createDirectory(at: tree.appending(name: "sub"))
        // New files; a taken name is refused.
        try write("fresh contents", to: tree.appending(name: "new").appending(name: "fresh.txt"), modified: stamp)
        try write("", to: tree.appending(name: "new").appending(name: "nothing"))
        #expect(throws: FileSystemError.self) { try write("x", to: tree.appending(name: "readme.txt")) }
        // Rename a file and a folder with everything in it.
        try bench.zip.move(tree.appending(name: "readme.txt"), to: tree.appending(name: "LIESMICH.txt"), replacing: false)
        try bench.zip.move(tree.appending(name: "sub"), to: tree.appending(name: "unter"), replacing: false)
        #expect(throws: FileSystemError.self) { try bench.zip.move(tree.appending(name: "big.log"), to: tree.appending(name: "empty.txt"), replacing: false) }
        try bench.zip.move(tree.appending(name: "big.log"), to: tree.appending(name: "empty.txt"), replacing: true)
        // A copy inside the archive shares the compressed data.
        try bench.zip.copy(tree.appending(name: "LIESMICH.txt"), to: tree.appending(name: "copy.txt")) { _ in true }
        // Delete: a file, an empty folder; a folder with contents is refused.
        try bench.zip.remove(tree.appending(name: "unter").appending(name: "random.bin"))
        try bench.zip.remove(tree.appending(name: "hollow"))
        #expect(throws: (any Error).self) { try bench.zip.remove(tree.appending(name: "unter")) }
        try bench.zip.setAttributes(FileAttributes(modified: stamp, permissions: 0o700), of: tree.appending(name: "copy.txt"))

        // Everything is visible at once, before the archive file is touched.
        #expect(FileSignature.of(archive.path) == before && bench.store.flushAll().isEmpty == true)
        #expect(FileSignature.of(archive.path) != before)
        #expect(namesOnDisk(box.root).filter { $0.hasSuffix(".tmp") }.isEmpty)
        for _ in 0..<2 {
            #expect(try bench.names(tree) == ["LIESMICH.txt", "copy.txt", "empty.txt", "new", "unter"])
            #expect(try bench.names(tree.appending(name: "unter")) == [".hidden", "deep"])
            #expect(try bench.names(tree.appending(name: "new")) == ["fresh.txt", "nested", "nothing"])
            let fresh = try bench.item(tree.appending(name: "new").appending(name: "fresh.txt"))
            #expect(fresh.size == 14 && fresh.modified == stamp && fresh.permissions == 0o600)
            #expect(try bench.read(fresh.url) == Data("fresh contents".utf8))
            #expect(try bench.read(tree.appending(name: "empty.txt")) == Data(contentsOf: box.url("tree/big.log")))
            #expect(try bench.read(tree.appending(name: "copy.txt")) == Data(contentsOf: box.url("tree/readme.txt")))
            #expect(try bench.item(tree.appending(name: "copy.txt")).permissions == 0o700)
            #expect(try bench.read(tree.appending(name: "unter").appending(name: "deep").appending(name: "übung – ñ 日本.txt")) == Data("unicode name".utf8))
            // The second round reads the archive afresh, as after a restart.
            bench.store.close()
        }

        // The system's unzip agrees with every byte of it.
        let check = runTool("/usr/bin/unzip", ["-tq", archive.path])
        #expect(check.status == 0, "\(check.output)")
        try box.folder("unzipped")
        #expect(runTool("/usr/bin/unzip", ["-q", archive.path, "-d", box.url("unzipped").path]).status == 0)
        let unzipped = snapshot(box.url("unzipped/tree"))
        #expect(unzipped.keys.sorted() == ["LIESMICH.txt", "copy.txt", "empty.txt", "new/fresh.txt", "new/nested", "new/nothing", "unter/.hidden",
                                           "unter/deep/übung – ñ 日本.txt"])
        #expect(unzipped["new/fresh.txt"] == Data("fresh contents".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: box.url("unzipped/tree/new/fresh.txt").path)
        #expect(attributes[.modificationDate] as? Date == stamp && attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func deletingTheLastFileKeepsItsFolder() throws {
        // The system's zip -D writes no entries for folders: they exist only through their files.
        try box.file("tree/a/b/only.txt", "only")
        #expect(runTool("/usr/bin/zip", ["-qrD", "bare.zip", "tree"], in: box.root).status == 0)
        let folder = bench.inside(box.url("bare.zip"), "tree/a/b")
        #expect(try bench.names(bench.inside(box.url("bare.zip"), "tree/a")) == ["b"])
        try bench.zip.remove(folder.appending(name: "only.txt"))
        #expect(try bench.names(folder).isEmpty)
        try bench.store.flush(box.url("bare.zip"))
        bench.store.close()
        #expect(try bench.names(folder).isEmpty && bench.item(folder).isDirectory)
        try bench.zip.remove(folder)
        try bench.zip.remove(folder.deletingLastPathComponent())
        try bench.zip.remove(bench.inside(box.url("bare.zip"), "tree"))
        try bench.store.flush(box.url("bare.zip"))
        // An archive without members is still an archive.
        #expect(try bench.names(bench.inside(box.url("bare.zip"))).isEmpty)
        #expect(try Data(contentsOf: box.url("bare.zip")).count == 22)
    }

    @Test func otherFormatsAndProtectedFilesRefuseChanges() throws {
        let tree = try bench.makeTree()
        try bench.pack([tree], to: box.url("tree.tar")) { $0.format = .tar }
        let inTar = bench.inside(box.url("tree.tar"), "tree", scheme: ArchiveURL.readOnlyScheme)
        #expect(throws: ArchiveError.self) { try bench.readOnly.createDirectory(at: inTar.appending(name: "new")) }
        #expect(throws: ArchiveError.self) { try bench.readOnly.remove(inTar.appending(name: "empty.txt")) }
        #expect(throws: ArchiveError.self) { _ = try bench.readOnly.write(inTar.appending(name: "x.txt")) }
        #expect(throws: FileSystemError.self) { try bench.readOnly.trash(inTar.appending(name: "empty.txt")) }
        // Between two archives the caller has to stream.
        let archive = try makeZip()
        #expect(throws: FileSystemError.self) {
            try bench.zip.copy(bench.inside(archive, "tree/empty.txt"), to: bench.inside(box.url("other.zip"), "x")) { _ in true }
        }
        // A ZIP that may not be written to says so at the first change, not when it is too late.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: archive.path)
        #expect(throws: (any Error).self) { try bench.zip.remove(bench.inside(archive, "tree/empty.txt")) }
        #expect(try bench.names(bench.inside(archive, "tree")).contains("empty.txt"))
    }

    @Test func aChangeFromOutsideIsNoticed() throws {
        let archive = try makeZip()
        let root = bench.inside(archive, "tree")
        #expect(try bench.names(root).count == 5)
        // Another program replaces the archive: the next question is answered from the new one.
        try FileManager.default.removeItem(at: archive)
        try box.file("other/solo.txt", "solo")
        #expect(runTool("/usr/bin/zip", ["-qr", "tree.zip", "other"], in: box.root).status == 0)
        #expect(bench.fileSystems.item(at: root) == nil)
        #expect(try bench.names(bench.inside(archive, "other")) == ["solo.txt"])

        // Changes waiting here are not written over an archive that was changed meanwhile:
        // what was done to its old members is given up and reported, and a new member is
        // added to the archive as it is now.
        try write("pending", to: bench.inside(archive, "other/pending.txt"))
        try bench.zip.move(bench.inside(archive, "other/solo.txt"), to: bench.inside(archive, "other/renamed.txt"), replacing: false)
        Thread.sleep(forTimeInterval: 0.02)
        #expect(runTool("/usr/bin/zip", ["-q", "tree.zip", "tree/empty.txt"], in: box.root).status == 0)
        let failures = bench.store.flushAll()
        #expect(failures.count == 1 && failures.first?.error.localizedDescription.contains("changed by another program") == true)
        #expect(try bench.names(bench.inside(archive)) == ["other", "tree"])
        #expect(try bench.names(bench.inside(archive, "other")) == ["pending.txt", "solo.txt"])
        #expect(runTool("/usr/bin/unzip", ["-tq", archive.path]).status == 0)
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "other/pending.txt"]).output == "pending")
    }

    @Test func changesAreWrittenShortlyAfterTheLastOne() throws {
        let archive = try makeZip()
        bench.environment.flushDelay = 0.15
        // The write is due at low priority; on a machine where that does not get to run
        // (every core busy with other tests), the urgent timer behind it does the work.
        bench.environment.escalationDelay = 0.3
        let changed = DispatchSemaphore(value: 0)
        bench.environment.contentsChanged = { _ in changed.signal() }
        let before = FileSignature.of(archive.path)
        // A member that is still being written holds the flush back.
        let writer = try bench.zip.write(bench.inside(archive, "tree/slow.txt"))
        try bench.zip.remove(bench.inside(archive, "tree/empty.txt"))
        try writer.write(Data("slow".utf8))
        #expect(changed.wait(timeout: .now() + 0.5) == .timedOut && FileSignature.of(archive.path) == before)
        try writer.close(attributes: FileAttributes())
        // (A generous wait: the timer runs at low priority, behind whatever else the machine does.)
        #expect(changed.wait(timeout: .now() + 60) == .success)
        #expect(FileSignature.of(archive.path) != before)
        let listed = runTool("/usr/bin/unzip", ["-Z1", archive.path]).output
        #expect(listed.contains("tree/slow.txt") && !listed.contains("empty.txt"))
    }

    // MARK: Nesting and other file systems

    @Test func archivesInsideArchives() throws {
        let tree = try bench.makeTree()
        try bench.pack([tree], to: box.url("inner.zip"))
        try bench.pack([tree], to: box.url("inner.tar.gz")) { $0.format = .compressedTar(.gzip) }
        try bench.pack([box.url("inner.zip"), box.url("inner.tar.gz")], to: box.url("outer.zip"))
        let outer = bench.inside(box.url("outer.zip"))
        #expect(try bench.names(outer) == ["inner.tar.gz", "inner.zip"])

        // Enter the inner archives; leaving them leads back into the outer one.
        let innerZip = ArchiveURL.make(scheme: "zip", archive: outer.appending(name: "inner.zip"))
        let innerTar = ArchiveURL.make(scheme: "archive", archive: outer.appending(name: "inner.tar.gz"))
        #expect(try bench.names(innerZip.appending(name: "tree")) == ["big.log", "empty.txt", "hollow", "readme.txt", "sub"])
        #expect(try bench.read(innerTar.appending(name: "tree").appending(name: "big.log")) == Data(contentsOf: tree.appendingPathComponent("big.log")))
        #expect(bench.zip.parent(of: innerZip)?.isSameLocation(as: outer) == true)
        #expect(bench.fileSystems.displayPath(innerZip.appending(name: "tree")) == box.url("outer.zip").path + "/inner.zip/tree")
        #expect(bench.zip.root(of: innerZip.appending(name: "tree")).isSameLocation(as: box.root))

        // A change deep inside travels outwards: the inner archive is rewritten, then the outer.
        try write("added inside", to: innerZip.appending(name: "tree").appending(name: "added.txt"))
        try bench.zip.remove(innerZip.appending(name: "tree").appending(name: "big.log"))
        #expect(bench.store.flushAll().isEmpty && bench.store.flushAll().isEmpty)
        bench.store.close()
        #expect(runTool("/usr/bin/unzip", ["-q", "outer.zip", "-d", "x"], in: box.root).status == 0)
        let listed = runTool("/usr/bin/unzip", ["-Z1", box.url("x/inner.zip").path]).output
        #expect(listed.contains("tree/added.txt") && !listed.contains("big.log") && listed.contains("tree/readme.txt"))
        #expect(runTool("/usr/bin/unzip", ["-tq", box.url("x/inner.zip").path]).status == 0)
        #expect(try bench.read(innerZip.appending(name: "tree").appending(name: "added.txt")) == Data("added inside".utf8))
    }

    @Test func anArchiveOnAnotherFileSystem() throws {
        let tree = try bench.makeTree()
        // Packed straight onto the other file system…
        let onServer = bench.memory.url("/store/tree.zip")
        try bench.pack([tree], to: onServer)
        #expect(bench.memory.allPaths == ["/store", "/store/tree.zip"])
        // …opened there, read, changed, and added to.
        let root = ArchiveURL.make(scheme: "zip", archive: onServer)
        #expect(try bench.names(root.appending(name: "tree")).count == 5)
        #expect(try bench.read(root.appending(name: "tree").appending(name: "readme.txt")).count == 17_600)
        #expect(bench.fileSystems.displayPath(root.appending(name: "tree")) == "mem:/store/tree.zip/tree")
        try bench.zip.remove(root.appending(name: "tree").appending(name: "big.log"))
        #expect(bench.store.flushAll().isEmpty)
        try box.file("more.txt", "more")
        try bench.pack([box.url("more.txt")], to: onServer, innerFolder: "tree/sub")
        #expect(bench.memory.allPaths == ["/store", "/store/tree.zip"])

        // What lies there now is a sound ZIP with the changes in it.
        let reader = try bench.memory.read(onServer)
        var bytes = Data()
        while let block = try reader.read(upToCount: 1 << 20) { bytes.append(block) }
        try bytes.write(to: box.url("fetched.zip"))
        #expect(runTool("/usr/bin/unzip", ["-tq", box.url("fetched.zip").path]).status == 0)
        let listed = runTool("/usr/bin/unzip", ["-Z1", box.url("fetched.zip").path]).output
        #expect(listed.contains("tree/sub/more.txt") && !listed.contains("big.log"))
        // A file system that cannot be written to makes its archives read-only.
        bench.memory.capabilities = []
        #expect(throws: ArchiveError.self) { try bench.zip.remove(root.appending(name: "tree").appending(name: "empty.txt")) }
        #expect(ArchiveFileSystem.scheme(forArchive: onServer, fileSystems: bench.fileSystems) == ArchiveURL.readOnlyScheme)
    }

    // MARK: The copy job

    @Test func theCopyJobStreamsOutOfAndIntoArchives() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        // Out: a folder with everything in it, onto the disk.
        try box.folder("out")
        var result = runJob(.copy, [tree.appending(name: "sub"), tree.appending(name: "readme.txt")], to: TargetSpec(directory: box.url("out")),
                            fileSystems: bench.fileSystems)
        #expect(result.completed.count == 2 && !result.cancelled)
        #expect(snapshot(box.url("out/sub")) == snapshot(box.url("tree/sub")))
        #expect(try Data(contentsOf: box.url("out/readme.txt")) == Data(contentsOf: box.url("tree/readme.txt")))
        let date = try FileManager.default.attributesOfItem(atPath: box.url("out/readme.txt").path)[.modificationDate] as? Date
        #expect(abs((date ?? .distantPast).timeIntervalSince(Date(timeIntervalSince1970: 1_600_000_000))) < 2)

        // In: a tree from the disk into a folder of the archive; an existing member is replaced.
        try box.file("in/alpha.txt", "alpha")
        try box.file("in/more/beta.txt", String(repeating: "beta ", count: 50_000))
        try box.file("in/readme.txt", "replaced")
        let answers = Answers()
        result = runJob(.copy, [box.url("in/alpha.txt"), box.url("in/more"), box.url("in/readme.txt")], to: TargetSpec(directory: tree),
                        answers: answers, fileSystems: bench.fileSystems)
        #expect(result.completed.count == 3 && answers.conflicts == ["readme.txt"] && answers.errors.isEmpty)
        // One rewrite of the archive for the whole job, however many files it brought.
        #expect(bench.store.flushAll().isEmpty)
        #expect(try bench.names(tree) == ["alpha.txt", "big.log", "empty.txt", "hollow", "more", "readme.txt", "sub"])
        #expect(runTool("/usr/bin/unzip", ["-tq", archive.path]).status == 0)
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/readme.txt"]).output == "replaced")
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/more/beta.txt"]).output.count == 250_000)

        // Move inside the archive is a rename; delete walks the tree.
        result = runJob(.move, [tree.appending(name: "more")], to: TargetSpec(directory: tree.appending(name: "hollow")), fileSystems: bench.fileSystems)
        #expect(try result.completed.count == 1 && bench.names(tree.appending(name: "hollow").appending(name: "more")) == ["beta.txt"])
        result = runJob(.delete(toTrash: false), [tree.appending(name: "hollow"), tree.appending(name: "big.log")], fileSystems: bench.fileSystems)
        #expect(result.completed.count == 2)
        // From one archive into another.
        try bench.pack([box.url("in/alpha.txt")], to: box.url("second.zip"))
        result = runJob(.copy, [tree.appending(name: "sub")], to: TargetSpec(directory: bench.inside(box.url("second.zip"))), fileSystems: bench.fileSystems)
        #expect(result.completed.count == 1 && bench.store.flushAll().isEmpty)
        let listed = runTool("/usr/bin/unzip", ["-Z1", box.url("second.zip").path]).output.split(separator: "\n").map(String.init).sorted()
        // (The system's unzip garbles the Unicode name when it lists; the name itself is checked above.)
        #expect(listed.count == 6 && Set(listed).isSuperset(of: ["alpha.txt", "sub/", "sub/.hidden", "sub/deep/", "sub/random.bin"]))
        #expect(try bench.names(bench.inside(box.url("second.zip"), "sub/deep")) == ["übung – ñ 日本.txt"])
        #expect(try bench.names(tree) == ["alpha.txt", "empty.txt", "readme.txt", "sub"])
        #expect(runTool("/usr/bin/unzip", ["-tq", archive.path]).status == 0 && runTool("/usr/bin/unzip", ["-tq", box.url("second.zip").path]).status == 0)
    }

    // MARK: Many threads

    @Test func manyThreadsUseTheProviderAtOnce() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree")
        try bench.pack([box.url("tree")], to: box.url("tree.tar.bz2")) { $0.format = .compressedTar(.bzip2) }
        let inTar = bench.inside(box.url("tree.tar.bz2"), "tree", scheme: ArchiveURL.readOnlyScheme)
        let expected = try Data(contentsOf: box.url("tree/big.log"))
        let failures = SharedCounter()
        // Readers, listers and writers on every core, on a ZIP that is being changed and on an
        // archive that is opened by all of them at the same moment.
        DispatchQueue.concurrentPerform(iterations: 48) { index in
            do {
                switch index % 6 {
                case 0:
                    if try bench.read(tree.appending(name: "big.log")) != expected { failures.add(1) }
                case 1:
                    if try bench.zip.list(tree, showHidden: true).count < 5 { failures.add(1) }
                    if bench.zip.item(at: tree.appending(name: "readme.txt"))?.size != 17_600 { failures.add(1) }
                case 2:
                    try write("thread \(index)", to: tree.appending(name: "sub").appending(name: "t\(index).txt"))
                case 3:
                    try bench.zip.createDirectory(at: tree.appending(name: "made\(index)"))
                    try bench.zip.move(tree.appending(name: "made\(index)"), to: tree.appending(name: "moved\(index)"), replacing: false)
                case 4:
                    if try bench.read(inTar.appending(name: "big.log")) != expected { failures.add(1) }
                    if try bench.readOnly.list(inTar, showHidden: true).count != 5 { failures.add(1) }
                default:
                    try bench.store.flush(archive)
                    if bench.zip.parent(of: tree) != bench.inside(archive) { failures.add(1) }
                }
            } catch {
                failures.add(1)
            }
        }
        #expect(failures.value == 0)
        #expect(bench.store.flushAll().isEmpty)
        let names = try bench.names(tree.appending(name: "sub"))
        #expect(names.filter { $0.hasPrefix("t") }.count == 8)
        #expect(try bench.names(tree).filter { $0.hasPrefix("moved") }.count == 8)
        #expect(runTool("/usr/bin/unzip", ["-tq", archive.path]).status == 0)
    }

    @Test func cancellingStopsPackingAndLeavesNothingBehind() throws {
        let tree = try bench.makeTree()
        bench.monitor.cancellation.cancel()
        var options = PackOptions()
        options.format = .compressedTar(.gzip)
        let packer = Packer(fileSystems: bench.fileSystems, store: bench.store, monitor: bench.monitor, options: options)
        let result = packer.run([try bench.item(tree)], archive: box.url("out/cancelled.tgz"))
        #expect(result.cancelled && result.archives.isEmpty && result.failure == nil)
        #expect(namesOnDisk(box.url("out")).isEmpty)
    }
}
