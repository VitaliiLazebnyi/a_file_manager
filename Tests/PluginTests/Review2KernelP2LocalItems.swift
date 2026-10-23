import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Review 2, second pass: what the local file system says about its entries.
@Suite
internal struct Review2KernelP2LocalItems {
    /// The local disks with the system's own probes, as the program uses them.
    internal let local = LocalFileSystem()

    /// A link to a file says how large the file is, besides its own size; links to anything else do not.
    @Test
    internal func aLinkToAFileSaysHowLargeThatFileIs() throws {
        let box = try Sandbox()
        try box.file("big.bin", "12345")
        try box.folder("folder")
        try FileManager.default.createSymbolicLink(atPath: box.url("to-file").path, withDestinationPath: "big.bin")
        try FileManager.default.createSymbolicLink(atPath: box.url("to-folder").path, withDestinationPath: "folder")
        try FileManager.default.createSymbolicLink(atPath: box.url("to-nothing").path, withDestinationPath: "missing")
        let listed = Dictionary(
            uniqueKeysWithValues: try local.list(box.root, showHidden: true).map { ($0.name, $0) }
        )
        // The link itself has no size (the entry is what `lstat` sees); the file's is said besides.
        #expect(
            listed["to-file"]?.size == 0 && listed["to-file"]?.linkTargetSize == 5
                && listed["to-file"]?.isSymlink == true
        )
        #expect(listed["to-folder"]?.linkTargetSize == nil && listed["to-folder"]?.isDirectory == true)
        #expect(
            listed["to-nothing"]?.linkTargetSize == nil && listed["big.bin"]?.linkTargetSize == nil
                && listed["big.bin"]?.size == 5
        )
        // Asked one by one, the same.
        for name in ["to-file", "to-folder", "to-nothing", "big.bin", "folder"] {
            #expect(local.item(at: box.root.appending(name: name)) == listed[name], "\(name)")
        }
        // The figure is the target's as it was when the entry was read: read again, it follows.
        try "1234567890".write(to: box.url("big.bin"), atomically: false, encoding: .utf8)
        #expect(local.item(at: box.url("to-file"))?.linkTargetSize == 10)
    }

    /// The top of a local location is `/` however deep it is, the same as going up from it gives.
    @Test
    internal func theTopOfEveryLocalLocationIsKnownWithoutGoingUp() {
        let deep = URL(fileURLWithPath: "/" + (0..<300).map { "d\($0)" }.joined(separator: "/"))
        #expect(local.root(of: deep).path == "/" && local.root(of: URL(fileURLWithPath: "/")).path == "/")
        // What going up gives, which is what the kernel did before.
        var climbed = deep
        while let parent = local.parent(of: climbed) { climbed = parent }
        #expect(local.root(of: deep).isSameLocation(as: climbed))
    }
}
