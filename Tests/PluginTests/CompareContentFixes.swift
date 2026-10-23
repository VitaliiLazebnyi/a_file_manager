import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin

/// The fixes of Compare by content.
@Suite
internal struct CompareContentFixes {
    /// Saving through a link writes where it leads, keeps the link, and keeps the file's tags.
    @Test
    internal func savingKeepsTheLinkAndTheTags() throws {
        let box = try Sandbox()
        let fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
        try Data("old\n".utf8).write(to: box.url("real.txt"))
        try FileManager.default.createSymbolicLink(at: box.url("link.txt"), withDestinationURL: box.url("real.txt"))
        let attribute = "com.example.tag"
        _ = box.url("real.txt")
            .withUnsafeFileSystemRepresentation { path in
                setxattr(path, attribute, "blue", 4, 0, 0)
            }
        try CompareLoader.replace(box.url("link.txt"), with: Data("new\n".utf8), fileSystems: fileSystems)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: box.url("link.txt").path)) != nil)
        #expect(try Data(contentsOf: box.url("real.txt")) == Data("new\n".utf8))
        let size = box.url("real.txt")
            .withUnsafeFileSystemRepresentation { path in getxattr(path, attribute, nil, 0, 0, 0) }
        #expect(size == 4)
    }

    /// Lines compared by their hashes give the same differences as by their keys.
    @Test
    internal func hashedKeysFindTheSameDifferencesAsBefore() {
        let options = DiffOptions()
        let left = ["Hello  World", "same", "tab\tx", "ÄÖ", "end"].map { text in TextLine(text) }
        let right = ["hello world", "same", "tab x", "äö", "END!"].map { text in TextLine(text) }
        for (one, two) in zip(left, right) {
            #expect((options.hash(one) == options.hash(two)) == (options.key(one) == options.key(two)))
        }
        let diff = TextDiff.compute(left: left, right: right, options: options)
        #expect(diff.rows.map(\.kind) == [.equal, .equal, .equal, .equal, .changed])
    }

    /// Inside a line the ends the two share are left out of the marked parts.
    @Test
    internal func insideALineTheCommonEndsAreTrimmed() {
        let ranges = TextDiff.inline("prefix-OLD-suffix", "prefix-NEWER-suffix")
        #expect(ranges.left == [7..<10] && ranges.right == [7..<12])
    }

    /// A row of binary mode shows its bytes in hex, padded, then as characters.
    @Test
    internal func binaryRowText() {
        let diff = BinaryDiff.compute(left: Data(), right: Data(), bytesPerLine: 8)
        #expect(
            diff.text(of: Data([0x41, 0x00, 0xFF]), row: 0) == "41 00 FF"
                + String(repeating: " ", count: 8 * 3 + 1 - 8) + "A.."
        )
    }
}
