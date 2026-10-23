/// What is taken from a server before it is called a hostile one.
///
/// No command of the protocol needs anywhere near this much.
public enum FTPLimits {
    /// The longest line of a reply, and of a listing, in bytes.
    public static let lineLength = 4_096
    /// The lines of one reply that are kept; what comes beyond is dropped.
    public static let replyLines = 1_000
    /// The bytes of one reply that are kept; what comes beyond is dropped.
    public static let replyBytes = 64 * 1_024
    /// The lines of one reply that are read at all before the connection is given up.
    public static let replyLinesRead = 20_000
    /// The entries of one directory listing that are read before the listing is given up.
    public static let listingEntries = 4_000_000
    /// The bytes of one directory listing that are read before the listing is given up.
    public static let listingBytes: Int64 = 1 << 30
}
