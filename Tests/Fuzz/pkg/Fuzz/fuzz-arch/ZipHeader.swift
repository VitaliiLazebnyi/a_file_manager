/// Where a ZIP header (a directory entry or a local header) lies, and where its name and the
/// name's length are.
internal struct ZipHeader {
    /// The offset of the "PK" signature.
    internal let start: Int
    /// The offset of the name.
    internal let nameAt: Int
    /// The offset of the name's length.
    internal let lengthAt: Int
}
