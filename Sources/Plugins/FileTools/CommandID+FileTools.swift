import AFMKernel

/// The commands of this plugin, under the names of the specification (17 › Command catalogue).
extension CommandID {
    /// Split File.
    internal static let splitFile: CommandID = "cm_Split"
    /// Combine Files.
    internal static let combineFiles: CommandID = "cm_Combine"
    /// Encode File.
    internal static let encodeFile: CommandID = "cm_Encode"
    /// Decode File.
    internal static let decodeFile: CommandID = "cm_Decode"
    /// Create Checksum File(s).
    internal static let createChecksums: CommandID = "cm_CRCcreate"
    /// Verify Checksums.
    internal static let verifyChecksums: CommandID = "cm_CRCcheck"
}
