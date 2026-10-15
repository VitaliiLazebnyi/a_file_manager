import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// The parts of file properties that work on values, beyond the other suites: comment files in
/// every encoding and with damaged lines, the questions to the system about users, groups,
/// flags and volumes, and links that cannot be made.
@Suite
internal struct CoverageFilePropertiesPure {
    /// An item of a file system in memory.
    private func memoryItem(_ name: String, kind: FileItem.Kind = []) -> FileItem {
        FileItem(url: URL(string: "mem:/A/" + name) ?? URL(fileURLWithPath: "/"), name: name, kind: kind)
    }

    /// No change of permissions reads as nothing and keeps the mode.
    @Test
    internal func anUnchangedModeIsKept() {
        #expect(PermissionChange.unchanged.text.isEmpty)
        #expect(PermissionChange.unchanged.applied(to: 0o640, isDirectory: false) == 0o640)
    }

    /// A comment file that does not decode in the encoding its mark announces has no comments;
    /// bytes the code page leaves undefined are read as Latin-1.
    @Test
    internal func undecodableCommentFiles() {
        let broken = DescriptIon(data: Data([0xFF, 0xFE, 0x00, 0xD8]))
        #expect(broken.isEmpty && broken.encoding == .ansi)
        let undefined = DescriptIon(data: Data("a.txt ".utf8) + Data([0x81]))
        #expect(undefined.comment(for: "a.txt") == "\u{81}" && undefined.encoding == .ansi)
    }

    /// A quoted name without its closing quote is no entry; of two entries for one name, the
    /// first counts.
    @Test
    internal func damagedLinesAndNamesTwice() {
        let file = DescriptIon(data: Data("\"long name x\r\na.txt first\r\nA.TXT second\r\n".utf8))
        #expect(file.entries.map(\.name) == ["a.txt", "A.TXT"])
        #expect(file.commentsByName == ["a.txt": "first"])
    }

    /// A file read as UTF-16, of either byte order, is written back in it.
    @Test
    internal func utf16FilesStayUTF16() {
        func utf16(_ text: String, bigEndian: Bool) -> Data {
            Data(
                text.utf16.flatMap { unit in
                    bigEndian ? [UInt8(unit >> 8), UInt8(unit & 0xFF)] : [UInt8(unit & 0xFF), UInt8(unit >> 8)]
                }
            )
        }
        for (mark, bigEndian) in [([UInt8(0xFF), 0xFE], false), ([UInt8(0xFE), 0xFF], true)] {
            var file = DescriptIon(data: Data(mark) + utf16("a.txt one\r\n", bigEndian: bigEndian))
            file.setComment("zwei", for: "b.txt")
            #expect(file.data() == Data(mark) + utf16("a.txt one\r\nb.txt zwei\r\n", bigEndian: bigEndian))
        }
    }

    /// The errors of the comment file say what happened.
    @Test
    internal func commentFileErrorsSayWhatHappened() {
        #expect(
            CommentFileError.unreadable.localizedDescription.hasPrefix("The comment file descript.ion cannot be read")
        )
        #expect(CommentFileError.unnameable.localizedDescription.hasPrefix("A name with a line break"))
    }

    /// Users and groups by number and by name; numbers no name belongs to are shown as numbers.
    @Test
    internal func usersAndGroups() {
        #expect(LocalInfo.userName(77_777) == "77777" && LocalInfo.groupName(77_777) == "77777")
        #expect(LocalInfo.userID("501") == 501 && LocalInfo.userID(NSUserName()) == getuid())
        #expect(LocalInfo.userID("afm-no-such-user") == nil)
        #expect(LocalInfo.groupID("20") == 20 && LocalInfo.groupID("staff") == 20)
        #expect(LocalInfo.groupID("afm-no-such-group") == nil)
    }

    /// Items of other file systems are described by what they are and their extension.
    @Test
    internal func kindsOfOtherItems() {
        #expect(LocalInfo.kind(of: memoryItem("link", kind: .init(isSymlink: true))) == "Symbolic link")
        #expect(LocalInfo.kind(of: memoryItem("README")) == "Document")
    }

    /// Volumes: only a local folder that is there has a cluster size.
    @Test
    internal func clusterSizes() {
        #expect(LocalInfo.clusterSize(at: memoryItem("x").url) == nil)
        #expect(LocalInfo.clusterSize(at: URL(fileURLWithPath: "/afm-there-is-no-such-folder")) == nil)
    }

    /// Flags and owners of what is not there, or on the read-only system volume, cannot be set;
    /// the error names the path.
    @Test
    internal func flagsAndOwnersThatCannotBeSet() {
        let missing = URL(fileURLWithPath: "/afm-there-is-no-such-file")
        let system = URL(fileURLWithPath: "/usr/bin")
        #expect(throws: (any Error).self) { try LocalInfo.setFlag(UInt32(UF_HIDDEN), true, of: missing) }
        #expect(throws: (any Error).self) { try LocalInfo.setFlag(UInt32(UF_HIDDEN), true, of: system) }
        #expect(throws: (any Error).self) { try LocalInfo.setOwner(0, group: nil, of: system) }
        let error = #expect(throws: (any Error).self) { try LocalInfo.setOwner(nil, group: 0, of: system) }
        #expect(error?.localizedDescription.hasSuffix(": /usr/bin") == true)
    }

    /// Links are made on the Mac's own disks only, and not where the system refuses them.
    @Test
    internal func linksThatCannotBeMade() throws {
        let box = try Sandbox()
        try box.file("a.txt")
        #expect(throws: (any Error).self) {
            try LinkMaker.create(.symbolic, to: memoryItem("a").url, at: box.url("l"), relative: false)
        }
        #expect(throws: (any Error).self) {
            try LinkMaker.create(.symbolic, to: box.url("a.txt"), at: box.url("missing/l"), relative: false)
        }
        #expect(throws: (any Error).self) {
            try LinkMaker.create(.hard, to: box.url("gone.txt"), at: box.url("h"), relative: false)
        }
        #expect(!box.exists("l") && !box.exists("h"))
    }

    /// The columns of an item elsewhere: a link without a target there, and a folder, whose
    /// size on disk is a command's business.
    @Test
    internal func columnsOfLinksElsewhereAndFolders() {
        let columns = ColumnRegistry()
        PropertyColumns.register(in: columns, comments: CommentStore(fileSystems: FileSystemRegistry()))
        let link = memoryItem("link", kind: .init(isSymlink: true))
        let folder = FileItem(url: URL(fileURLWithPath: "/tmp"), name: "tmp", kind: .init(isDirectory: true))
        #expect(columns["linkTarget"]?.value(link).isEmpty == true)
        #expect(columns["sizeOnDisk"]?.value(folder).isEmpty == true)
    }
}
