internal import Foundation

/// Cuts what a data connection delivers into lines, block by block.
///
/// Every byte is looked at once, whatever the sizes of the blocks; a line longer than `limit` is
/// dropped whole, so the part of a line that is waiting for its end never grows beyond the limit.
internal struct LineSplitter {
    /// The longest line that is passed on, in bytes, without its line end.
    internal let limit: Int
    private var partial = Data()
    /// True while the rest of a line that was too long is being skipped.
    private var isSkipping = false
    /// How many lines were dropped for their length.
    internal private(set) var dropped = 0

    /// A splitter that drops lines longer than `limit` bytes (`FTPLimits.lineLength` for FTP).
    internal init(limit: Int) {
        self.limit = limit
    }

    /// The lines that `block` completes, without their line ends (LF, or CR LF).
    internal mutating func feed(_ block: Data) -> [Data] {
        var lines: [Data] = []
        var start = block.startIndex
        while start < block.endIndex {
            guard let end = block[start...].firstIndex(of: 0x0A) else {
                if !isSkipping {
                    if partial.count + (block.endIndex - start) > limit {
                        (isSkipping, partial) = (true, Data())
                        dropped += 1
                    } else {
                        partial.append(block[start...])
                    }
                }
                break
            }
            if isSkipping {
                isSkipping = false
            } else if partial.count + (end - start) > limit + 1 {
                partial = Data()
                dropped += 1
            } else {
                var line = partial.isEmpty ? Data(block[start..<end]) : partial + block[start..<end]
                partial = Data()
                if line.last == 0x0D { line.removeLast() }
                lines.append(line)
            }
            start = end + 1
        }
        return lines
    }

    /// What is left when the data ends without a line end.
    internal mutating func finish() -> Data? {
        defer { (partial, isSkipping) = (Data(), false) }
        if isSkipping || partial.isEmpty {
            return nil
        }
        return partial.last == 0x0D ? Data(partial.dropLast()) : partial
    }
}
