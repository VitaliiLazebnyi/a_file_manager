/// Text from a server, which may send any bytes where UTF-8 is expected.
extension String {
    /// The text of UTF-8 bytes; every sequence that is not valid UTF-8 becomes U+FFFD.
    ///
    /// The same text as `String(decoding:as:)` gives, a byte order mark included, where the
    /// failable `String(bytes:encoding:)` would give nothing or drop the mark.
    internal init(repairingUTF8 bytes: some Sequence<UInt8>) {
        var scalars = Self.UnicodeScalarView()
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        decoding: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                scalars.append(scalar)

            case .emptyInput:
                break decoding

            case .error:
                scalars.append("\u{FFFD}")
            }
        }
        self = String(scalars)
    }
}
