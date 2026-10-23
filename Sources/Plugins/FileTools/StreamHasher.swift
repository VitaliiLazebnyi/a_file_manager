import Foundation

/// A checksum that is fed a file block by block.
///
/// One hasher belongs to one thread at a time, and may go from one thread to another between
/// blocks.
internal protocol StreamHasher: AnyObject, Sendable {
    /// Adds the next block of the input.
    func update(_ data: Data)
    /// The digest; the hasher is used up afterwards.
    func finish() -> [UInt8]
}
