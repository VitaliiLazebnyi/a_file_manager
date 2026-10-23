import Foundation

/// Decoded text with, for every UTF-16 unit, the position of the byte it came from.
///
/// The positions are what let a place in the shown text be found in the file again (selection,
/// search results, the row index).
internal struct DecodedText {
    /// The text as UTF-16 units; a replacement character for each byte that makes no sense.
    internal var units: [UInt16] = []
    /// Byte offset of each unit, counted from the start of the decoded bytes.
    ///
    /// The two halves of a surrogate pair share one offset.
    internal var offsets: [Int32] = []
    /// Off for callers that only want the text (copying, HTML): `offsets` then stays empty and
    /// nothing is spent on it.
    internal var tracksOffsets = true

    /// The text as a string.
    internal var string: String { String(decoding: units, as: UTF16.self) }

    /// Empties the text, keeping the room it had for the next one.
    internal mutating func removeAll() {
        units.removeAll(keepingCapacity: true)
        offsets.removeAll(keepingCapacity: true)
    }

    /// Adds `unit`, which came from the byte at `offset` (the offset only when they are tracked).
    @inline(__always)
    internal mutating func append(_ unit: UInt16, _ offset: Int) {
        units.append(unit)
        if tracksOffsets { offsets.append(Int32(truncatingIfNeeded: offset)) }
    }
}
