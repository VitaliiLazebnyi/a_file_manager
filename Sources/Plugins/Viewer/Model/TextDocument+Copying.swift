import AFMKernel
import Foundation

/// The text of a part of the file, for the clipboard.
extension TextDocument {
    /// The bytes of `range` as text for the clipboard, in the document's encoding; NUL becomes
    /// a space (spec 10 › Selection and clipboard).
    ///
    /// Blocks.
    internal func text(in range: Range<Int64>, cancellation: CancellationFlag?) throws -> String {
        var text = DecodedText()
        text.tracksOffsets = false
        encoding.decode(try source.read(range, cancellation: cancellation), final: true, into: &text)
        for position in text.units.indices where text.units[position] == 0 { text.units[position] = 0x20 }
        return text.string
    }
}
