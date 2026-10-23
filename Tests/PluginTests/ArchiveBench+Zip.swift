import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// A ZIP of the standard tree, and text written to a member, for the suites that change archives.
extension ArchiveBench {
    /// A ZIP of the standard tree made by the system's zip, in the sandbox under `name`.
    internal func zipOfTree(_ name: String) throws -> URL {
        try makeTree("tree")
        #expect(runTool("/usr/bin/zip", ["-qr", name, "tree"], in: box.root).status == 0)
        return box.url(name)
    }

    /// Writes `text` to `url` through the file system that serves it, with the given date (nil: now).
    internal func writeText(_ text: String, to url: URL, modified: Date?) throws {
        let writer = try fileSystems.provider(for: url).write(url)
        try writer.write(Data(text.utf8))
        try writer.close(attributes: FileAttributes(modified: modified, permissions: 0o600))
    }
}
