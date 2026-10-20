import Foundation
import Security
import zlib

/// Large files and ZIP archives for the UI tests, written a megabyte at a time.
internal enum LastZip {
    /// The fixed fields of a stored member made on 1 January 1980, in its local header and in
    /// the central directory.
    private struct Fields {
        let crc: UInt32
        let size: UInt32
        let nameLength: UInt16

        /// The local header, up to the name.
        var local: Data {
            var data = Data()
            Self.put(UInt32(0x0403_4b50), into: &data)
            for value: UInt16 in [20, 0, 0, 0, 0x21] { Self.put(value, into: &data) }
            for value in [crc, size, size] { Self.put(value, into: &data) }
            for value in [nameLength, 0] { Self.put(value, into: &data) }
            return data
        }

        /// Appends `value` to `data`, least significant byte first.
        static func put(_ value: some FixedWidthInteger, into data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        /// The entry in the central directory, up to the name, for a member at `offset`.
        func central(offset: UInt32) -> Data {
            var data = Data()
            Self.put(UInt32(0x0201_4b50), into: &data)
            for value: UInt16 in [20, 20, 0, 0, 0, 0x21] { Self.put(value, into: &data) }
            for value in [crc, size, size] { Self.put(value, into: &data) }
            for value in [nameLength, 0, 0, 0, 0] { Self.put(value, into: &data) }
            for value: UInt32 in [0, offset] { Self.put(value, into: &data) }
            return data
        }
    }

    /// Writes `megabytes` MB of random bytes to `file`, each megabyte different: nothing makes
    /// them smaller, so compressing them takes as long as their size says.
    internal static func writeNoise(megabytes: Int, to file: URL) throws {
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        guard SecRandomCopyBytes(kSecRandomDefault, chunk.count, &chunk) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        for index in 0..<megabytes {
            withUnsafeBytes(of: UInt32(index).littleEndian) { chunk.replaceSubrange(0..<4, with: $0) }
            try handle.write(contentsOf: chunk)
        }
    }

    /// Writes a ZIP archive of `files` (each under 4 GB), stored, each by its name.
    internal static func zip(_ files: [URL], to archive: URL) throws {
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        defer { try? handle.close() }
        var central = Data()
        var offset = 0
        for file in files {
            var crc = crc32(0, nil, 0)
            var size = 0
            try read(file) { block in
                crc = block.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                size += block.count
            }
            let name = Data(file.lastPathComponent.utf8)
            let fields = Fields(crc: UInt32(crc), size: UInt32(size), nameLength: UInt16(name.count))
            try handle.write(contentsOf: fields.local + name)
            try read(file) { try handle.write(contentsOf: $0) }
            central += fields.central(offset: UInt32(offset)) + name
            offset += 30 + name.count + size
        }
        var end = Data([0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0])
        Fields.put(UInt16(files.count), into: &end)
        Fields.put(UInt16(files.count), into: &end)
        Fields.put(UInt32(central.count), into: &end)
        Fields.put(UInt32(offset), into: &end)
        Fields.put(UInt16(0), into: &end)
        try handle.write(contentsOf: central + end)
    }

    /// Calls `body` with the contents of `file`, a megabyte at a time.
    private static func read(_ file: URL, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            try body(block)
        }
    }
}
