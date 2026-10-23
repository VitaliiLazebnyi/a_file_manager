/// A stream that can continue at any position without reading what lies between.
internal protocol SeekableStream: ByteStream {
    /// `offset` counts from the first byte of the stream; past the end means the end.
    func seek(to offset: UInt64)
}
