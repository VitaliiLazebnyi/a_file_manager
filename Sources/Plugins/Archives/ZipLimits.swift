import Foundation

/// Above these values ZIP needs its 64-bit extension (ZIP64).
///
/// They are parameters so that the rules can be tested without files of four gigabytes.
internal struct ZipLimits: Equatable {
    /// The limits of the format itself.
    internal static let standard = Self()

    /// The largest size or offset the classic 32-bit fields may hold.
    internal var maxField: UInt64 = 0xFFFF_FFFE
    /// The largest number of members the classic end record may count.
    internal var maxEntries: Int = 0xFFFE
}
