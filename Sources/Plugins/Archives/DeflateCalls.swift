import zlib

/// The two calls of zlib that compress: the one that starts a raw deflate stream at a level,
/// and the one that runs it with a flush mode.
///
/// The system's; a test passes calls that fail as zlib can fail (no memory, a stream in a state it
/// does not accept).
internal struct DeflateCalls: Sendable {
    /// A raw stream, without the zlib or gzip wrapping.
    internal static let zlib = Self(
        start: { stream, level in
            deflateInit2_(
                stream,
                level,
                Z_DEFLATED,
                -15,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        },
        run: { stream, flush in deflate(stream, flush) }
    )

    /// Starts the stream at a level from 1 to 9; zlib's status comes back (`Z_OK` when it started).
    internal let start: @Sendable (UnsafeMutablePointer<z_stream>, Int32) -> Int32
    /// Compresses what the stream is given, with a flush mode; zlib's status comes back.
    internal let run: @Sendable (UnsafeMutablePointer<z_stream>, Int32) -> Int32
}
