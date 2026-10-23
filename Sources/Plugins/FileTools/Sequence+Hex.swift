import Foundation

/// Bytes written as hex digits.
extension Sequence where Element == UInt8 {
    /// The bytes as lower-case hex digits, two to a byte: what checksum files hold.
    internal var hex: String { map { byte in String(format: "%02x", byte) }.joined() }
}
