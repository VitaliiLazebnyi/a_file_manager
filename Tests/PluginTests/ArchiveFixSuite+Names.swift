import AFMKernel
import Foundation

@testable import ArchivesPlugin

/// ZIPs with names no packer would write.
extension ArchiveFixSuite {
    /// A ZIP of empty members under exactly `names` (taken as they are, unchecked), written with `limits`.
    internal func writeZip(_ name: String, limits: ZipLimits, names: [String]) throws -> URL {
        try writeZip(name, limits: limits) { writer in
            for member in names {
                var record = ZipRecord.new(
                    name: member,
                    isDirectory: false,
                    modified: Date(),
                    permissions: 0o644,
                    isSymbolicLink: false
                )
                record.setName(member)
                try writer.end(
                    try writer.begin(record, localExtra: nil, expectedSize: nil),
                    record,
                    headerChanged: false
                )
            }
        }
    }
}
