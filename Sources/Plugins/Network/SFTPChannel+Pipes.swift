import AFMKernel
import Foundation

/// Reading and writing the pipes of the child process, packet by packet.
extension SFTPChannel {
    /// The longest packet that is accepted from the server.
    internal static let largestPacket = 1 << 20

    /// How long a writer that was cancelled in the middle of a packet goes on while the pipe
    /// takes nothing at all.
    private static let cancelGrace: TimeInterval = 2

    /// Reads packets until the stream ends or `handle` returns false.
    ///
    /// Runs on the reading thread.
    internal static func readPackets(from input: FileHandle, handle: (SFTPPacket) -> Bool) {
        while let header = readExactly(4, from: input) {
            let length = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            // Nothing the protocol sends is this large (a read brings 32 KB, OpenSSH never sends more
            // than 256 KB); a wrong length means the stream is not SFTP, and is not made room for.
            guard length >= 1, length <= Self.largestPacket, let payload = readExactly(length, from: input),
                let kind = SFTPPacket.Kind(rawValue: payload[0])
            else { return }
            // The body is a view of the payload; nothing is copied.
            if !handle(SFTPPacket(kind: kind, body: payload.dropFirst())) {
                return
            }
        }
    }

    /// Writes all of `packet` into the pipe.
    ///
    /// The pipe does not block: when it is full the writer waits for room, up to `writeTimeout`
    /// without progress. A cancellation is obeyed at once before the first byte. After it, the
    /// packet is finished for as long as the pipe keeps taking bytes: the channel is shared, a
    /// packet left half written would end the dialogue for every transfer, and a packet is small (a
    /// block of a file at most), so on a slow line, where the pipe is always full but always
    /// moving, cancelling one upload costs the others nothing. Only when the pipe takes nothing for
    /// `cancelGrace` is the cancelled writer let go, and the channel with it: that line is not
    /// moving for anybody.
    ///
    /// `descriptor` does not block (a write that does not block is not interrupted by a signal);
    /// `isClosed` says whether the channel was closed meanwhile.
    internal static func writeAll(
        _ packet: Data,
        to descriptor: Int32,
        writeTimeout: TimeInterval,
        cancellation: CancellationFlag?,
        isClosed: () -> Bool
    ) throws {
        try packet.withUnsafeBytes { buffer in
            var sent = 0
            var moved = Date()
            while sent < buffer.count {
                // A channel that was closed meanwhile sends nothing more, also while the pipe takes it.
                guard !isClosed() else { throw NetworkError.connectionLost }
                // Inside the loop the buffer holds bytes, so it has an address.
                let count = Darwin.write(descriptor, buffer.baseAddress?.advanced(by: sent), buffer.count - sent)
                if count > 0 {
                    sent += count
                    moved = Date()
                    continue
                }
                guard count < 0, errno == EAGAIN else { throw NetworkError.connectionLost }
                let stuck = Date().timeIntervalSince(moved)
                if stuck >= writeTimeout { throw NetworkError.timedOut("sending to the server") }
                if cancellation?.isCancelled == true {
                    if sent == 0 { throw NetworkError.cancelled }
                    if stuck >= cancelGrace { throw NetworkError.connectionLost }
                }
                var wanted = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&wanted, 1, 200)
            }
        }
    }

    /// `count` bytes of `input`; nil when the stream ends first.
    ///
    /// `FileHandle` reads again when a signal interrupts it; a failure is the end of the stream.
    private static func readExactly(_ count: Int, from input: FileHandle) -> Data? {
        var data = Data()
        while data.count < count {
            guard let piece = try? input.read(upToCount: count - data.count), !piece.isEmpty else {
                return nil
            }
            data.append(piece)
        }
        return data
    }
}
