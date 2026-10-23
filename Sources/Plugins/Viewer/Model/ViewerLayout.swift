import Foundation

/// The three ways bytes are laid out in rows (spec 10 › Display modes 1–3; Unicode and UTF-8
/// are text in another encoding).
internal enum ViewerLayout: Equatable {
    /// A continuous stream of characters cut into rows of a fixed number of bytes.
    case binary(width: Int)
    /// Offset, sixteen bytes in hex, the same bytes as characters.
    case hex
    /// Text, cut into rows at its line ends and as the options say.
    case text(TextLayoutOptions)
}
