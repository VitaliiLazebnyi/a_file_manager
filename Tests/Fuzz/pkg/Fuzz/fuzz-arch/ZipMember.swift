/// One member as a ZIP's central directory names it.
internal struct ZipMember {
    /// The name, as bytes.
    internal let name: [UInt8]
    /// The general purpose flags; bit 0 says the member is encrypted.
    internal let flags: Int
    /// The compression method; 99 is WinZip AES.
    internal let method: Int
    /// The extra field.
    internal let extra: [UInt8]
}
