/// Text of the system: a C string in a buffer.
internal enum SystemText {
    /// The characters before the first zero, read as UTF-8; all of them when there is no zero.
    internal static func string(_ buffer: [CChar]) -> String {
        String(repairingUTF8: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
    }
}
