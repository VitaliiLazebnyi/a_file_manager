import AFMKernel
import Foundation

/// Writing a copy onto the disk.
extension CopyDisk {
    /// Writes what `reader` reads into the new file `target`, at most `sizeLimit` bytes; the bytes written, or why
    /// it stopped.
    ///
    /// A read that waits for a server is ended by `cancellation`; what it threw then is no end of the file.
    internal func write(
        _ reader: any FileReader,
        to target: URL,
        cancellation: CancellationFlag
    ) -> Result<Int64, TemporaryCopies.Refusal> {
        let descriptor = createFile(target)
        guard descriptor >= 0 else {
            return .failure(.unreadable)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var written: Int64 = 0
        var refusal: TemporaryCopies.Refusal?
        let limit = sizeLimit
        func nextBlock() throws -> Data? {
            try autoreleasepool { try reader.read(upToCount: 1 << 20) }
        }
        let copied = cancellation.whileReading(reader) { () -> Bool in
            do {
                while let block = try nextBlock(), !block.isEmpty {
                    guard !cancellation.isCancelled else {
                        return false
                    }
                    written += Int64(block.count)
                    // A size that the listing did not tell is limited as it is read.
                    guard written <= limit else {
                        refusal = .tooLarge(written, limit: limit)
                        return false
                    }
                    try handle.write(contentsOf: block)
                }
                return !cancellation.isCancelled
            } catch {
                return false
            }
        }
        guard copied else {
            return .failure(refusal ?? (cancellation.isCancelled ? .cancelled : .unreadable))
        }
        return .success(written)
    }
}
