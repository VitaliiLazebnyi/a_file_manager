import Foundation
import TestSupport

@testable import ArchivesPlugin

/// What the coverage tests of the open archives share: archives made by the system's tools,
/// and what the system's tools say about them.
internal enum CoverageArchives {
    /// Makes `files` (path → text) in a folder of `box` and packs them with the system's zip
    /// into `name`; `options` go to zip in front of the names.
    internal static func zip(
        _ name: String,
        in box: Sandbox,
        _ files: [String: String],
        options: [String]
    ) throws -> URL {
        let folder = "source-\(UUID().uuidString)"
        for (path, text) in files {
            try box.file("\(folder)/\(path)", text)
        }
        let archive = box.url(name)
        let result = runTool(
            "/usr/bin/zip",
            ["-q"] + options + [archive.path] + files.keys.sorted(),
            in: box.url(folder)
        )
        guard result.status == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: result.output])
        }
        return archive
    }

    /// The names the system's unzip lists in an archive.
    internal static func listed(_ archive: URL) -> [String] {
        runTool("/usr/bin/unzip", ["-Z1", archive.path]).output.split(separator: "\n").map(String.init)
    }

    /// True when the system's unzip finds every member of an archive sound.
    internal static func isSound(_ archive: URL) -> Bool {
        runTool("/usr/bin/unzip", ["-tq", archive.path]).status == 0
    }

    /// What the system's unzip unpacks from one member.
    internal static func contents(of member: String, in archive: URL) -> String {
        runTool("/usr/bin/unzip", ["-p", archive.path, member]).output
    }

    /// Writes a ZIP of stored members with the plugin's own writer, for archives the system's
    /// zip cannot make; `shape` may change each record before it is written, and `localExtra`
    /// gives the extra field of the headers in front of the data.
    internal static func craft(
        _ url: URL,
        _ members: [(name: String, data: Data)],
        localExtra: Data?,
        shape: (inout ZipRecord) -> Void
    ) throws {
        let output = try OutputFile(creating: url, mode: 0o600)
        let writer = ZipWriter(output, limits: .standard)
        for member in members {
            var record = ZipRecord.new(
                name: member.name,
                isDirectory: false,
                modified: Date(timeIntervalSince1970: 1_600_000_000),
                permissions: 0o644,
                isSymbolicLink: false
            )
            (record.crc, record.compressedSize, record.uncompressedSize) = (
                CRC32.of(member.data), UInt64(member.data.count), UInt64(member.data.count)
            )
            shape(&record)
            let opened = try writer.begin(record, localExtra: localExtra, expectedSize: nil)
            try writer.append(member.data)
            try writer.end(opened, record, headerChanged: false)
        }
        try writer.finish(comment: Data())
        try output.close(durably: false)
    }

    /// Puts another archive in the place of `archive`, as another program would: a new file
    /// under the same name.
    internal static func replace(_ archive: URL, with other: URL) throws {
        let copy = archive.deletingLastPathComponent().appendingPathComponent("replacement-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: other, to: copy)
        guard rename(copy.path, archive.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
