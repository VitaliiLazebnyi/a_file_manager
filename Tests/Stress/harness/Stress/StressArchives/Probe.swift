import Foundation

/// A member whose bytes the harness knows.
internal struct Probe {
    /// The member's path inside the archive.
    internal let path: String
    /// Its bytes.
    internal let data: Data
    /// Its CRC-32.
    internal let crc: UInt32

    /// The 64 probes of the big archive: `probe.tsv` (path, size, CRC) and their bytes in `probe-ref`.
    internal static func load(from directory: URL) -> [Self] {
        let table: String
        do {
            table = try String(contentsOf: directory.appendingPathComponent("probe.tsv"), encoding: .utf8)
        } catch {
            preconditionFailure("probe.tsv cannot be read: \(error)")
        }
        return table.split(separator: "\n").map { line in reference(String(line), in: directory) }
    }

    /// The probe of one line of `probe.tsv`, checked against its size and CRC.
    private static func reference(_ line: String, in directory: URL) -> Self {
        let parts = line.split(separator: "\t").map(String.init)
        let names = parts.first?.split(separator: "/") ?? []
        guard parts.count >= 3, names.count >= 2, let size = Int(parts[1]), let expectedCRC = UInt32(parts[2]) else {
            preconditionFailure("probe.tsv has a line that is not path, size and CRC: \(line)")
        }
        let file = directory.appendingPathComponent("probe-ref").appendingPathComponent(String(names[1]))
        let bytes: Data
        do {
            bytes = try Data(contentsOf: file)
        } catch {
            preconditionFailure("reference of \(parts[0]) cannot be read: \(error)")
        }
        precondition(bytes.count == size && checksum(bytes) == expectedCRC, "reference of \(parts[0]) is wrong")
        return Self(path: parts[0], data: bytes, crc: expectedCRC)
    }
}
