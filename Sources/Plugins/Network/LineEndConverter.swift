import Foundation

/// Converts line ends for transfers in text mode: the network form is CR LF, the Mac's is LF.
///
/// Runs between the line ends are copied as blocks.
internal struct LineEndConverter {
    private var pendingCR = false

    /// Network to Mac.
    ///
    /// A CR at the end of a block waits for the next block.
    internal mutating func toLocal(_ data: Data) -> Data {
        var result = Data(capacity: data.count)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress, !bytes.isEmpty else {
                return
            }
            let count = bytes.count
            var start = 0
            if pendingCR {
                pendingCR = false
                if bytes[0] != 0x0A { result.append(0x0D) }
            }
            var index = 0
            while index < count, let found = memchr(base + index, 0x0D, count - index) {
                let crIndex = base.distance(to: UnsafeRawPointer(found))
                // The CR itself stays out of the run; it is dropped before an LF and kept before anything else.
                result.append(base.assumingMemoryBound(to: UInt8.self) + start, count: crIndex - start)
                if crIndex + 1 == count {
                    pendingCR = true
                    start = count
                    index = count
                } else {
                    if bytes[crIndex + 1] != 0x0A { result.append(0x0D) }
                    start = crIndex + 1
                    index = crIndex + 1
                }
            }
            result.append(base.assumingMemoryBound(to: UInt8.self) + start, count: count - start)
        }
        return result
    }

    /// What is left when the data ends on a CR.
    internal mutating func finishLocal() -> Data {
        defer { pendingCR = false }
        return pendingCR ? Data([0x0D]) : Data()
    }

    /// Mac to network: every LF that does not already follow a CR gets one.
    internal mutating func toNetwork(_ data: Data) -> Data {
        var result = Data(capacity: data.count + data.count / 32)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress, !bytes.isEmpty else {
                return
            }
            let count = bytes.count
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            var start = 0
            var index = 0
            while index < count, let found = memchr(base + index, 0x0A, count - index) {
                let lfIndex = base.distance(to: UnsafeRawPointer(found))
                let followsCR = lfIndex == 0 ? pendingCR : bytes[lfIndex - 1] == 0x0D
                if !followsCR {
                    result.append(pointer + start, count: lfIndex - start)
                    result.append(0x0D)
                    start = lfIndex
                }
                index = lfIndex + 1
            }
            result.append(pointer + start, count: count - start)
            pendingCR = bytes[count - 1] == 0x0D
        }
        return result
    }
}
