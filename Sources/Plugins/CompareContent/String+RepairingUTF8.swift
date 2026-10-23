/// Text made from bytes that should be UTF-8.
extension String {
    /// The text of `bytes` read as UTF-8, a replacement character standing for each sequence that is not valid.
    ///
    /// For bytes known to be valid (cut from a text at its line breaks) this is a copy; for a file that is not
    /// valid in its encoding it is what can be shown of it.
    internal init(repairingUTF8 bytes: some Collection<UInt8>) {
        self.init(unsafeUninitializedCapacity: bytes.count) { buffer in
            buffer.initialize(fromContentsOf: bytes)
        }
    }
}
