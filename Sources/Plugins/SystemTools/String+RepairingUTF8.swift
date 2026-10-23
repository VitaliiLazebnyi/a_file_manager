/// Text made from bytes that should be UTF-8.
extension String {
    /// The text of `bytes` read as UTF-8, a replacement character standing for each sequence that is not valid.
    ///
    /// What the system or a program printed is shown even when a byte of it is broken.
    internal init(repairingUTF8 bytes: some Collection<UInt8>) {
        self.init(unsafeUninitializedCapacity: bytes.count) { buffer in
            buffer.initialize(fromContentsOf: bytes)
        }
    }
}
