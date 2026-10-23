/// Text made from bytes that should be UTF-8.
extension String {
    /// The text of `bytes` read as UTF-8, a replacement character standing for each sequence that is not valid.
    ///
    /// What can be read of a damaged file: the rest is not a checksum line and is reported as such.
    internal init(repairingUTF8 bytes: some Collection<UInt8>) {
        self.init(unsafeUninitializedCapacity: bytes.count) { buffer in
            buffer.initialize(fromContentsOf: bytes)
        }
    }
}
