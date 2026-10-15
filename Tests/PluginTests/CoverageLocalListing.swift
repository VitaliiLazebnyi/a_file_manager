import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Listing a folder: without bulk reads, when a read fails, when the caller stops early, and what a bulk read says
/// about an entry it could not read.
@Suite
internal struct CoverageLocalListing {
    /// A reply of `getattrlistbulk` for one entry with an error and a name, as the system lays it out.
    private static func reply(error: UInt32, name: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { bytes += $0 } }
        let returned = attribute_set_t(
            commonattr: attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_NAME),
            volattr: 0,
            dirattr: 0,
            fileattr: 0,
            forkattr: 0
        )
        let length = 4 + MemoryLayout<attribute_set_t>.size + 4 + MemoryLayout<attrreference_t>.size + name.count + 1
        append(UInt32(length))
        append(returned)
        append(error)
        // The name follows its reference, which says where it is from the reference's own place.
        append(attrreference_t(attr_dataoffset: Int32(MemoryLayout<attrreference_t>.size), attr_length: 0))
        bytes += name + [0]
        return bytes
    }

    /// A volume without bulk reads is listed entry by entry.
    @Test
    internal func aVolumeWithoutBulkReadsIsListedEntryByEntry() throws {
        let box = try Sandbox()
        try box.file("a.txt", "12")
        try box.file(".hidden")
        try box.folder("folder")
        let local = CoverageLocalProbes.failing("getattrlistbulk", endingIn: box.root.lastPathComponent, ENOTSUP)
        let shown = try local.list(box.root, showHidden: false).map(\.name).sorted()
        #expect(shown == ["a.txt", "folder"])
        let all = try local.list(box.root, showHidden: true)
        #expect(all.map(\.name).sorted() == [".hidden", "a.txt", "folder"])
        #expect(all.first { $0.name == "a.txt" }?.size == 2)
        // A caller that wants no more after the first batch gets no more.
        var batches = 0
        try local.list(box.root, showHidden: true) { _ in
            batches += 1
            return false
        }
        #expect(batches == 1)
    }

    /// A listing cancelled as the volume says it has no bulk reads ends quietly.
    @Test
    internal func aListingCancelledAsTheVolumeSaysItHasNoBulkReadsEndsQuietly() throws {
        let box = try Sandbox()
        try box.file("a.txt")
        let flag = CancellationFlag()
        var probes = LocalProbes()
        probes.fault = { call, _ in
            guard call == "getattrlistbulk" else {
                return nil
            }
            flag.cancel()
            return ENOTSUP
        }
        let local = LocalFileSystem(probes: probes)
        var received: [FileItem] = []
        try local.list(box.root, showHidden: true, cancellation: flag) { batch in
            received += batch
            return true
        }
        #expect(received.isEmpty)
    }

    /// A bulk read that fails is an error.
    @Test
    internal func aBulkReadThatFailsIsAnError() throws {
        let box = try Sandbox()
        try box.file("a.txt")
        let local = CoverageLocalProbes.failing("getattrlistbulk", endingIn: box.root.lastPathComponent, EIO)
        #expect { try local.list(box.root, showHidden: true) } throws: { CoverageLocalProbes.code($0) == Int(EIO) }
        // After entries were delivered, even "not supported" is a failure of the read.
        let later = CoverageLocalProbes.failing(
            "getattrlistbulk",
            endingIn: box.root.lastPathComponent,
            ENOTSUP,
            after: 1
        )
        var delivered: [String] = []
        #expect {
            try later.list(box.root, showHidden: true, cancellation: CancellationFlag()) { batch in
                delivered += batch.map(\.name)
                return true
            }
        } throws: { error in
            CoverageLocalProbes.code(error) == Int(ENOTSUP)
        }
        #expect(delivered == ["a.txt"])
    }

    /// A listing cancelled while the folder is opened ends quietly.
    @Test
    internal func aListingCancelledWhileTheFolderIsOpenedEndsQuietly() throws {
        let box = try Sandbox()
        try box.file("a.txt")
        let flag = CancellationFlag()
        var probes = LocalProbes()
        probes.willAsk = { _ in flag.cancel() }
        let local = LocalFileSystem(probes: probes)
        #expect(try local.list(box.root, showHidden: true, cancellation: flag).isEmpty)
    }

    /// An entry the system could not read is marked and a name that is not UTF8 is repaired.
    @Test
    internal func anEntryTheSystemCouldNotReadIsMarkedAndANameThatIsNotUTF8IsRepaired() throws {
        let bytes = Self.reply(error: UInt32(EIO), name: [0x61, 0xFF, 0x62])
        let (entry, length) = try #require(
            bytes.withUnsafeBytes { raw in raw.baseAddress.map { LocalFileSystem.Entry.read(at: $0) } }
        )
        #expect(length == bytes.count)
        #expect(entry.failed)
        #expect(entry.isNameRepaired && entry.name.hasPrefix("a") && entry.name.hasSuffix("b"))
        let plain = Self.reply(error: 0, name: Array("ok.txt".utf8))
        let read = try #require(
            plain.withUnsafeBytes { raw in raw.baseAddress.map { LocalFileSystem.Entry.read(at: $0) } }
        )
        .entry
        #expect(!read.failed && !read.isNameRepaired && read.name == "ok.txt")
    }

    /// An entry that failed is asked for by itself.
    @Test
    internal func anEntryThatFailedIsAskedForByItself() throws {
        let box = try Sandbox()
        try box.file("there.txt", "123")
        try box.file(".secret")
        let local = LocalFileSystem()
        var entry = LocalFileSystem.Entry()
        entry.failed = true
        entry.name = "there.txt"
        #expect(local.item(of: entry, in: box.root, showHidden: false)?.size == 3)
        entry.name = ".secret"
        #expect(local.item(of: entry, in: box.root, showHidden: false) == nil)
        #expect(local.item(of: entry, in: box.root, showHidden: true)?.name == ".secret")
        entry.name = "gone.txt"
        #expect(local.item(of: entry, in: box.root, showHidden: true) == nil)
    }

    /// An entry with a repaired name is shown but never opened.
    @Test
    internal func anEntryWithARepairedNameIsShownButNeverOpened() throws {
        let box = try Sandbox()
        var entry = LocalFileSystem.Entry()
        entry.name = "bad\u{FFFD}name"
        entry.type = VREG.rawValue
        entry.isNameRepaired = true
        let item = try #require(LocalFileSystem().item(of: entry, in: box.root, showHidden: true))
        #expect(item.isSpecial && item.name == "bad\u{FFFD}name")
    }
}
