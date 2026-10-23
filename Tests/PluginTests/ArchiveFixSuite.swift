import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// A suite of tests of the archives: a bench, and the helpers the suites share.
internal protocol ArchiveFixSuite {
    /// The archive file systems and the sandbox of the test.
    var bench: ArchiveBench { get }
}

/// The helpers every archive suite shares.
extension ArchiveFixSuite {
    /// The test's own folder on the local disk.
    internal var box: Sandbox { bench.box }

    /// A ZIP of the standard tree made by the system's zip, named "tree.zip".
    internal func makeZip() throws -> URL {
        try makeZip("tree.zip")
    }

    /// A ZIP of the standard tree made by the system's zip, in the sandbox under `name`.
    internal func makeZip(_ name: String) throws -> URL {
        try bench.makeTree()
        #expect(runTool("/usr/bin/zip", ["-qr", name, "tree"], in: box.root).status == 0)
        return box.url(name)
    }

    /// Writes `text` to `url` through the file system that serves it.
    internal func write(_ text: String, to url: URL) throws {
        let writer = try bench.fileSystems.provider(for: url).write(url)
        try writer.write(Data(text.utf8))
        try writer.close(attributes: FileAttributes())
    }

    /// The names of the members of `archive`, as the system's unzip lists them.
    internal func listed(_ archive: URL) -> [String] {
        runTool("/usr/bin/unzip", ["-Z1", archive.path]).output.split(separator: "\n").map(String.init)
    }

    /// Whether the system's unzip finds `archive` sound.
    internal func isSound(_ archive: URL) -> Bool {
        runTool("/usr/bin/unzip", ["-tq", archive.path]).status == 0
    }

    /// A ZIP written record by record with the standard limits, for directories no packer would write.
    internal func writeZip(_ name: String, _ fill: (ZipWriter) throws -> Void) throws -> URL {
        try writeZip(name, limits: .standard, fill)
    }

    /// A ZIP written record by record with the given limits, for directories no packer would write.
    internal func writeZip(_ name: String, limits: ZipLimits, _ fill: (ZipWriter) throws -> Void) throws -> URL {
        let url = box.url(name)
        let output = try OutputFile(creating: url, mode: 0o600)
        let writer = ZipWriter(output, limits: limits)
        try fill(writer)
        try writer.finish(comment: Data())
        try output.close(durably: false)
        return url
    }

    /// A place that does not run through the archive: the archive scheme hands it to the file
    /// system the archive lies on.
    internal func outside(_ root: URL, _ path: String) throws -> URL {
        var components = try #require(URLComponents(url: root, resolvingAgainstBaseURL: false))
        components.path = path
        return try #require(components.url)
    }

    /// Puts the quarantine mark `value` on the file at `url`.
    internal func mark(_ url: URL, with value: String) {
        #expect(value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) } == 0)
    }

    /// The quarantine mark of the file at `url` as text, or nil when it has none.
    internal func quarantineMark(of url: URL) -> String? {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else {
            return nil
        }
        var value = [UInt8](repeating: 0, count: size)
        let got = getxattr(url.path, "com.apple.quarantine", &value, size, 0, XATTR_NOFOLLOW)
        return got > 0 ? String(bytes: value.prefix(got), encoding: .utf8) : nil
    }
}
