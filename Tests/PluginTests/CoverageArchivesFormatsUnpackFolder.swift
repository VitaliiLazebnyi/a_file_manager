import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The folder an archive is unpacked into, held open: names, links and refusals of the disk.
@Suite
internal struct CoverageArchivesFormatsUnpackFolder {
    private typealias Support = CoverageArchivesFormatsSupport

    private let box: Sandbox

    /// A new folder for each test.
    internal init() throws {
        box = try Sandbox()
    }

    private func write(_ folder: UnpackFolder, _ names: [String], replacing: Bool = false, _ text: String) throws {
        try folder.write(
            names,
            replacing: replacing,
            permissions: 0o644,
            modified: Date(),
            quarantine: nil,
            opened: nil
        ) { put in
            try put(Data(text.utf8))
        }
    }

    /// A folder that is not there cannot be unpacked into.
    @Test
    internal func aMissingFolderCannotBeOpened() {
        let missing = box.url("missing")
        #expect(Support.failure { _ = try UnpackFolder(missing) } == Support.systemError(ENOENT, missing.path))
    }

    /// Names that are not one name, or none, are refused for folders, links and files.
    @Test
    internal func namesThatAreNotOneNameAreRefused() throws {
        let folder = try UnpackFolder(try box.folder("target"))
        #expect(
            Support.failure { try folder.makeFolder(["a", ".."], quarantine: nil) }
                == ArchiveError.unsupported("Unpacking to the name ..").errorDescription
        )
        let empty = ArchiveError.unsupported("Unpacking to an empty name").errorDescription
        #expect(Support.failure { try folder.makeLink([], to: "x", replacing: false) } == empty)
        #expect(Support.failure { try write(folder, [], "x") } == empty)
    }

    /// A folder the disk does not let be made is reported with its place.
    @Test
    internal func aFolderTheDiskRefusesIsReported() throws {
        let target = try box.folder("target")
        let folder = try UnpackFolder(target)
        chmod(target.path, 0o555)
        defer { chmod(target.path, 0o755) }
        let place = target.path + "/sub"
        #expect(
            Support.failure { try folder.makeFolder(["sub"], quarantine: nil) } == Support.systemError(EACCES, place)
        )
        #expect(
            Support.failure { try write(folder, ["file.txt"], "x") }
                == Support.systemError(EACCES, target.path + "/file.txt")
        )
    }

    /// A link replaces what stands under its name only when asked to.
    @Test
    internal func aLinkReplacesOnlyWhenAsked() throws {
        let target = try box.folder("target")
        let folder = try UnpackFolder(target)
        try box.file("target/link", "a file")
        #expect(
            Support.failure { try folder.makeLink(["link"], to: "elsewhere", replacing: false) }
                == Support.systemError(EEXIST, target.path + "/link")
        )
        try folder.makeLink(["link"], to: "elsewhere", replacing: true)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path + "/link") == "elsewhere")
    }

    /// A file replaces what stands under its name only when asked to; nothing temporary stays.
    @Test
    internal func aFileReplacesOnlyWhenAsked() throws {
        let target = try box.folder("target")
        let folder = try UnpackFolder(target)
        try box.file("target/file.txt", "old")
        #expect(
            Support.failure { try write(folder, ["file.txt"], "new") }
                == Support.systemError(EEXIST, target.path + "/file.txt")
        )
        #expect(box.read("target/file.txt") == "old")
        try write(folder, ["file.txt"], replacing: true, "new")
        #expect(box.read("target/file.txt") == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["file.txt"])
    }
}
