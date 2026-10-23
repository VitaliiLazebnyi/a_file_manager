import Foundation

/// The `.crc` file Split writes next to the parts (spec 08 › The `.crc` file): the original
/// name, size and CRC32 in three lines that end in CRLF.
internal struct SplitInfo: Equatable {
    /// The name of the file that was split.
    internal var name: String
    /// Its size in bytes.
    internal var size: Int64
    /// Its CRC32.
    internal var crc: UInt32

    /// The text of the `.crc` file.
    internal var text: String {
        "filename=\(name)\r\nsize=\(size)\r\ncrc32=\(String(format: "%08X", crc))\r\n"
    }

    /// The information of a file of `size` bytes named `name`, with the CRC32 `crc`.
    internal init(name: String, size: Int64, crc: UInt32) {
        self.name = name
        self.size = size
        self.crc = crc
    }

    /// The information a `.crc` file holds; nil when a line is missing or unreadable.
    internal init?(text: String) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else {
                continue
            }
            values[line[..<equals].lowercased()] = String(line[line.index(after: equals)...])
        }
        guard let fileName = values["filename"], !fileName.isEmpty,
            let byteCount = values["size"].flatMap({ value in Int64(value) }),
            let checksum = values["crc32"].flatMap({ value in UInt32(value, radix: 16) })
        else {
            return nil
        }
        self.init(name: fileName, size: byteCount, crc: checksum)
    }
}
