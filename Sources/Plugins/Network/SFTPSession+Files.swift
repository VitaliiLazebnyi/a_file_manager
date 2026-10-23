import AFMKernel
import Foundation

/// Opening files for reading, writing and continuing.
extension SFTPSession {
    /// Opens a file for reading from its start.
    internal func openRead(_ path: String, cancellation: CancellationFlag?) throws -> any FileReader {
        try perform(cancellation: cancellation) { channel in
            let handle = try openHandle(.open, on: channel, cancellation: cancellation) { encoder in
                encoder.string(path)
                encoder.u32(1)
                encoder.attributes(SFTPAttributes())
            }
            return SFTPFileReader(session: self, channel: channel, handle: handle)
        }
    }

    /// Creates a file and opens it for writing; the server refuses when the file exists.
    internal func openWrite(_ path: String, cancellation: CancellationFlag?) throws -> any FileWriter {
        try perform(cancellation: cancellation) { channel in
            // Write, create, and fail if the file exists.
            let handle = try openHandle(.open, on: channel, cancellation: cancellation) { encoder in
                encoder.string(path)
                encoder.u32(0x02 | 0x08 | 0x20)
                encoder.attributes(SFTPAttributes())
            }
            return SFTPFileWriter(session: self, channel: channel, handle: handle, position: 0)
        }
    }

    /// Every server can write at any position of a file it has open.
    internal func canAppend(_: String) -> Bool { true }

    /// Opens the file for writing without creating or emptying it, cuts it to `offset` when it is
    /// longer (`fsetstat` with a size), and writes from there.
    internal func openAppend(_ path: String, at offset: Int64?, cancellation: CancellationFlag?) throws -> (
        writer: any FileWriter, size: Int64
    ) {
        try perform(cancellation: cancellation) { channel in
            let handle = try openHandle(.open, on: channel, cancellation: cancellation) { encoder in
                encoder.string(path)
                encoder.u32(0x02)
                encoder.attributes(SFTPAttributes())
            }
            do {
                let target = try continuationStart(
                    handle,
                    of: path,
                    to: offset,
                    on: channel,
                    cancellation: cancellation
                )
                return (
                    SFTPFileWriter(session: self, channel: channel, handle: handle, position: UInt64(target)), target
                )
            } catch {
                closeHandle(handle, on: channel)
                throw error
            }
        }
    }

    /// Where a continued file is written from: `offset`, or its end without one.
    ///
    /// A file longer than `offset` is cut there first; one that is shorter cannot be continued
    /// there and throws.
    private func continuationStart(
        _ handle: Data,
        of path: String,
        to offset: Int64?,
        on channel: SFTPChannel,
        cancellation: CancellationFlag?
    ) throws -> Int64 {
        var found =
            try channel.request(.fstat, timeout: timeout, cancellation: cancellation) { $0.bytes(handle) }
            .expect(.attributes)
        let size = Int64(clamping: try found.attributes().size ?? 0)
        let target = offset ?? size
        guard target >= 0, target <= size else {
            throw FileSystemError.notSupported("Continuing \(path) at \(target), it has \(size) bytes")
        }
        if target < size {
            var shorter = SFTPAttributes()
            shorter.size = UInt64(target)
            try channel.request(.fsetstat, timeout: timeout, cancellation: cancellation) { encoder in
                encoder.bytes(handle)
                encoder.attributes(shorter)
            }
            .checkStatus()
        }
        return target
    }
}
