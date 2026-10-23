import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// The metadata of copied folders and files: tags, flags, creation dates, permissions.
@Suite
internal struct FileOpsAdoptMetadata {
    /// The extended attribute that holds the Finder's tags.
    private static let tagName = "com.apple.metadata:_kMDItemUserTags"

    /// A copied folder keeps its tags, its hidden flag and its creation date, and so do its subfolders.
    @Test
    internal func aCopiedFolderKeepsItsTagHiddenFlagAndCreationDate() throws {
        let box = try Sandbox()
        let tree = try box.folder("A/tree")
        try box.file("A/tree/in.txt", "inside")
        let sub = try box.folder("A/tree/sub")
        try box.file("A/tree/sub/deep.txt", "deep")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        for folder in [tree, sub] {
            setTag(folder)
            var values = URLResourceValues()
            values.creationDate = date
            var url = folder
            try url.setResourceValues(values)
        }
        #expect(chflags(sub.path, UInt32(UF_HIDDEN)) == 0)
        try box.folder("B")
        let result = Answers()
            .run(.copy, [tree], to: TargetSpec(directory: box.url("B")), fileSystems: makeFileSystems().0)
        #expect(result.completed == [tree])
        for name in ["B/tree", "B/tree/sub"] {
            let copy = box.url(name)
            #expect(tag(copy) == "tagvalue", "\(name)")
            #expect(abs((created(copy) ?? .distantPast).timeIntervalSince(date)) < 1, "\(name)")
        }
        #expect(flags(box.url("B/tree/sub")) & UInt32(UF_HIDDEN) != 0)
        #expect(box.read("B/tree/sub/deep.txt") == "deep" && box.read("B/tree/in.txt") == "inside")
    }

    /// Folders made only when a filtered file arrives get their metadata and permissions like the others.
    @Test
    internal func foldersMadeLateBecauseOfAFilterAreFinishedLikeTheOthers() throws {
        let box = try Sandbox()
        let tree = try box.folder("A/tree")
        try box.file("A/tree/sub/deep.txt", "deep")
        try box.file("A/tree/skipped/other.bin", "other")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        for folder in [tree, box.url("A/tree/sub")] {
            setTag(folder)
            var values = URLResourceValues()
            values.creationDate = date
            var url = folder
            try url.setResourceValues(values)
            #expect(chmod(folder.path, 0o750) == 0)
        }
        try box.folder("B")
        let job = FileJob(
            kind: .copy,
            sources: [tree],
            target: TargetSpec(directory: box.url("B")),
            fileSystems: FileSystemRegistry.localDisk()
        )
        // Folders are made when the first file arrives in them.
        job.options.filter = CopyFilter("*.txt | **/")
        let answers = Answers()
        job.delegate = answers
        #expect(withExtendedLifetime(answers) { job.run() }.completed == [tree])
        #expect(box.read("B/tree/sub/deep.txt") == "deep" && !box.exists("B/tree/skipped"))
        for name in ["B/tree", "B/tree/sub"] {
            let copy = box.url(name)
            #expect(tag(copy) == "tagvalue", "\(name)")
            #expect(abs((created(copy) ?? .distantPast).timeIntervalSince(date)) < 1, "\(name)")
            var info = stat()
            #expect(stat(copy.path, &info) == 0 && info.st_mode & 0o777 == 0o750, "\(name)")
        }
    }

    /// A folder locked in the Finder is copied with all it holds and locked like the original.
    @Test
    internal func aFinderLockedFolderIsCopiedCompletelyAndLockedLikeTheOriginal() throws {
        let box = try Sandbox()
        let locked = try box.folder("A/locked")
        try box.file("A/locked/one.txt", "1")
        try box.file("A/locked/inner/two.txt", "2")
        try box.folder("B")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer {
            chflags(box.url("A/locked").path, 0)
            chflags(box.url("B/locked").path, 0)
        }
        let result = Answers()
            .run(.copy, [locked], to: TargetSpec(directory: box.url("B")), fileSystems: makeFileSystems().0)
        #expect(result.completed == [locked])
        #expect(box.read("B/locked/one.txt") == "1" && box.read("B/locked/inner/two.txt") == "2")
        #expect(flags(box.url("B/locked")) & UInt32(UF_IMMUTABLE) != 0)
        #expect(!namesOnDisk(box.url("B/locked")).contains { $0.hasPrefix(".afm-") })
    }

    /// A link that is followed is copied as the file it points to, with that file's tags.
    @Test
    internal func aFollowedLinkKeepsTheTagsOfItsTarget() throws {
        let box = try Sandbox()
        let real = try box.file("A/real.txt", "target contents")
        setTag(real, "linked")
        let link = box.url("A/link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try box.folder("B")
        let replies = Replies()
        replies.run(.copy, [link], to: TargetSpec(directory: box.url("B")), fileSystems: makeFileSystems().0) { job in
            job.options.links = .followLinks
        }
        let copy = box.url("B/link.txt")
        #expect(box.read("B/link.txt") == "target contents")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: copy.path)) == nil)
        #expect(tag(copy) == "linked")
    }

    /// Only folders the job made get metadata, and only while attributes are kept.
    @Test
    internal func foldersTheJobCreatedAreGivenTheirMetadataLastAndOnlyWhenAttributesAreKept() {
        let base = MemoryFileSystem()
        base.keepsMetadata = true
        base.addFile("/src/tree/a.txt")
        base.addFile("/src/tree/sub/b.txt")
        base.addDirectory("/dst")
        let fileSystems = FileSystemRegistry.localDisk(and: base)
        Answers()
            .run(.copy, [base.url("/src/tree")], to: TargetSpec(directory: base.url("/dst")), fileSystems: fileSystems)
        let copies = base.metadataCopies
        #expect(Set(copies.map(\.to)) == ["/dst/tree", "/dst/tree/sub"])
        #expect(Set(copies.map(\.from.path)) == ["/src/tree", "/src/tree/sub"])

        // Without "keep dates and permissions" nothing is carried.
        let plain = MemoryFileSystem()
        plain.keepsMetadata = true
        plain.addFile("/src/tree/a.txt")
        plain.addDirectory("/dst")
        Replies()
            .run(
                .copy,
                [plain.url("/src/tree")],
                to: TargetSpec(directory: plain.url("/dst")),
                fileSystems: FileSystemRegistry.localDisk(and: plain)
            ) { $0.options.preservesAttributes = false }
        #expect(plain.metadataCopies.isEmpty)

        // A folder that was merged into is not the job's: it keeps what it has.
        let merged = MemoryFileSystem()
        merged.keepsMetadata = true
        merged.addFile("/src/tree/a.txt")
        merged.addFile("/dst/tree/old.txt")
        Answers()
            .run(
                .copy,
                [merged.url("/src/tree")],
                to: TargetSpec(directory: merged.url("/dst")),
                fileSystems: FileSystemRegistry.localDisk(and: merged)
            )
        #expect(merged.metadataCopies.isEmpty)
    }

    /// A file system that keeps no metadata still gets a complete copy without failures.
    @Test
    internal func aFileSystemThatKeepsNoMetadataDoesNotSpoilTheCopy() {
        let base = MemoryFileSystem()
        base.addFile("/src/tree/a.txt", "a")
        base.addDirectory("/dst")
        let result = Answers()
            .run(
                .copy,
                [base.url("/src/tree")],
                to: TargetSpec(directory: base.url("/dst")),
                fileSystems: FileSystemRegistry.localDisk(and: base)
            )
        #expect(result.completed.count == 1 && result.failureCount == 0)
        #expect(base.contents("/dst/tree/a.txt") == "a")
    }

    /// Gives the item a tag attribute of that value.
    private func setTag(_ url: URL, _ value: String = "tagvalue") {
        let bytes = Array(value.utf8)
        _ = setxattr(url.path, Self.tagName, bytes, bytes.count, 0, XATTR_NOFOLLOW)
    }

    /// The item's tag attribute as text; nil when it has none.
    private func tag(_ url: URL) -> String? {
        let size = getxattr(url.path, Self.tagName, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, Self.tagName, &bytes, size, 0, XATTR_NOFOLLOW) == size else {
            return nil
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// The item's file flags (hidden, locked); 0 when it cannot be read.
    private func flags(_ url: URL) -> UInt32 {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_flags : 0
    }

    /// The item's creation date.
    private func created(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}
