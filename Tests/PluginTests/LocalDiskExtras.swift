import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// What the local file system keeps when it copies, and what it tells about its surroundings.
@Suite
internal struct LocalDiskExtras {
    /// The file system under test.
    internal let local = LocalFileSystem()

    /// A copy has the creation date, the extended attributes and the rights of its source, and an
    /// existing destination is refused.
    @Test
    internal func aCopyKeepsCreationDateExtendedAttributesAndFlags() throws {
        let box = try Sandbox()
        var source = try box.file("a.txt", "content", modified: Date(timeIntervalSince1970: 1_700_000_000))
        var values = URLResourceValues()
        values.creationDate = Date(timeIntervalSince1970: 1_500_000_000)
        try source.setResourceValues(values)
        #expect(setxattr(source.path, "com.example.note", "hello", 5, 0, 0) == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        try local.copy(source, to: box.url("b.txt")) { _ in true }
        let copy = try FileManager.default.attributesOfItem(atPath: box.url("b.txt").path)
        #expect(copy[.creationDate] as? Date == Date(timeIntervalSince1970: 1_500_000_000))
        #expect(
            copy[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_700_000_000)
                && copy[.posixPermissions] as? Int == 0o640
        )
        var buffer = [UInt8](repeating: 0, count: 16)
        let length = getxattr(box.url("b.txt").path, "com.example.note", &buffer, 16, 0, 0)
        #expect(length == 5 && String(bytes: buffer[..<5], encoding: .utf8) == "hello")
        // An existing destination is refused and stays as it is.
        #expect(throws: (any Error).self) { try local.copy(source, to: box.url("b.txt")) { _ in true } }
    }

    /// A locked file refuses every change but the right to write, which unlocks it.
    @Test
    internal func makingALockedFileWritableUnlocksIt() throws {
        let box = try Sandbox()
        let file = try box.file("locked.txt", "l")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }
        #expect(throws: (any Error).self) { try local.remove(file) }
        // Changing only the date does not touch the lock, and so fails like any other change.
        #expect(throws: (any Error).self) { try local.setAttributes(FileAttributes(modified: Date()), of: file) }
        try local.setAttributes(FileAttributes(permissions: 0o644), of: file)
        #expect(local.item(at: file)?.permissions == 0o644)
        try local.remove(file)
        #expect(!box.exists("locked.txt"))
    }

    /// A location that does not exist yet is answered for the volume of the folder it will be in.
    @Test
    internal func volumesAreFoundAlsoForPlacesThatDoNotExistYet() throws {
        let box = try Sandbox()
        let here = try #require(local.volume(of: box.root))
        #expect(
            here.isLocal && (here.freeBytes ?? 0) > 0 && (here.totalBytes ?? 0) >= (here.freeBytes ?? 0)
                && !here.name.isEmpty
        )
        let future = try #require(local.volume(of: box.url("not/yet/there.txt")))
        #expect(future.name == here.name && future.isLocal)
        let file = try box.file("f.txt")
        #expect(local.volume(of: file)?.name == here.name)
        #expect(local.volume(of: URL(fileURLWithPath: "/"))?.isLocal == true)
    }

    /// The places are home and its usual folders, Applications, iCloud Drive when there is one, and
    /// the start-up disk once.
    @Test
    internal func placesListTheUsualFoldersAndTheVolumes() {
        let places = local.settledPlaces()
        #expect(places.first?.kind == .home && places.first?.name == "Home")
        let names = places.map(\.name)
        #expect(names.starts(with: ["Home", "Desktop", "Documents", "Downloads"]) && names.contains("Applications"))
        #expect(places.first { $0.name == "Applications" }?.url.path == "/Applications")
        // The start-up disk is there once, as an internal disk; every place has its own location.
        #expect(places.filter { $0.url.path == "/" }.map(\.kind) == [.internalDisk])
        #expect(Set(places.map(\.url.path)).count == places.count)
        // iCloud Drive appears exactly when this user has one.
        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs"
            )
            .path
        #expect(names.contains("iCloud Drive") == FileManager.default.fileExists(atPath: cloud))
    }

    /// The folder above a path is found by its text, slashes at the end ignored, as the walk up to
    /// the nearest existing folder needs it.
    @Test
    internal func theFolderAboveAPathIsFoundByItsText() {
        #expect(LocalFileSystem.parentPath(of: "/a/b") == "/a")
        #expect(LocalFileSystem.parentPath(of: "/a/b/") == "/a")
        #expect(LocalFileSystem.parentPath(of: "/a/é/c") == "/a/é")
        #expect(LocalFileSystem.parentPath(of: "/a") == "/")
        #expect(LocalFileSystem.parentPath(of: "/") == "/")
        #expect(LocalFileSystem.parentPath(of: "name").isEmpty)
    }

    /// A mount table and a table of remote changes besides the program's own read and count
    /// alike, and go away when nobody holds them.
    @Test
    internal func aMountTableAndATableOfRemoteChangesOfTheirOwnWorkLikeTheShared() {
        weak var table: MountTable?
        weak var changes: RemoteChanges?
        do {
            let ownTable = MountTable()
            let ownChanges = RemoteChanges()
            #expect(ownTable.mount(containing: "/").path == "/" && ownTable.isLocal("/"))
            #expect(ownChanges.strandedCalls(on: "/") == 0)
            (table, changes) = (ownTable, ownChanges)
        }
        #expect(table == nil && changes == nil)
    }
}
