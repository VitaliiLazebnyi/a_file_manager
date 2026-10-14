import Foundation

/// One file of a tree the harness makes: where it goes and what it holds.
internal struct Entry: Sendable {
    /// The path below the tree's folder.
    internal let path: String
    /// Chooses the content; no two files of a run share it.
    internal let index: Int
    /// The size in bytes.
    internal let size: Int

    /// The files of the local tree: `fileCount` small ones spread over `folderCount` folders, and
    /// `bigCount` large ones in `big`.
    internal static func manifest(fileCount: Int, folderCount: Int, bigCount: Int) -> [Self] {
        var entries: [Self] = []
        entries.reserveCapacity(fileCount + bigCount)
        let perFolder = max(1, fileCount / folderCount)
        for number in 0..<fileCount {
            let folder = min(folderCount - 1, number / perFolder)
            let name = String(format: "d%04d/f%06d.dat", folder, number)
            entries.append(Self(path: name, index: number, size: 16 + (number &* 7_919) % 2_048))
        }
        // Larger than FileJob.smallFileLimit (4 MB): copied one after another, as a stream.
        for number in 0..<bigCount {
            let name = String(format: "big/b%02d.bin", number)
            entries.append(Self(path: name, index: fileCount + number, size: (5 << 20) + number * (1 << 20) + 17))
        }
        return entries
    }

    /// The bytes the file holds: the same for the same index and size, every time.
    internal func content() -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            var state = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15 &+ 12_345
            var position = 0
            while position < size {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                var word = state
                var count = min(8, size - position)
                while count > 0 {
                    buffer[position] = UInt8(truncatingIfNeeded: word)
                    word >>= 8
                    position += 1
                    count -= 1
                }
            }
        }
        return data
    }
}
