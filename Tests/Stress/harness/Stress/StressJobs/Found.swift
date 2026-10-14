import Foundation

/// What is on disk where an entry belongs.
internal enum Found {
    /// A file with another size or other bytes (the size found).
    case different(Int)
    /// The entry's file, byte for byte.
    case identical
    /// Nothing.
    case missing

    /// Looks at the file of `entry` below the folder `base`.
    internal static func look(_ base: String, _ entry: Entry) -> Self {
        let path = base + "/" + entry.path
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            return .missing
        }
        defer { close(descriptor) }
        var status = stat()
        fstat(descriptor, &status)
        guard Int(status.st_size) == entry.size else {
            return .different(Int(status.st_size))
        }
        var content = Data(count: entry.size)
        let got = content.withUnsafeMutableBytes { raw in readAll(descriptor, into: raw) }
        guard got == entry.size else {
            return .different(got)
        }
        return content == entry.content() ? .identical : .different(entry.size)
    }

    /// Reads from `descriptor` until `buffer` is full or the file ends; the number of bytes read.
    private static func readAll(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        guard let start = buffer.baseAddress else {
            return 0
        }
        var total = 0
        while total < buffer.count {
            let count = read(descriptor, start + total, buffer.count - total)
            if count <= 0 {
                break
            }
            total += count
        }
        return total
    }
}
