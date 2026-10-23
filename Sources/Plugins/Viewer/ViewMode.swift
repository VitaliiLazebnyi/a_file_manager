/// The display modes of the Options menu, numbered as their keys (spec 10 › Mode list).
internal enum ViewMode: Int, CaseIterable {
    /// Bytes as fixed-length rows, 2 on the keyboard.
    case binary = 2
    /// Hex dump, 3.
    case hex = 3
    /// HTML with the tags stripped, 5.
    case html = 5
    /// An image, PDF, audio or video, 4.
    case media = 4
    /// The Quick Look preview, 8.
    case preview = 8
    /// Plain text, 1.
    case text = 1
    /// UTF-16 text, 6.
    case unicode = 6
    /// UTF-8 text, 7.
    case utf8 = 7

    /// Every mode in the order of its key, as the Options menu lists them.
    internal static let allCases: [Self] = [.text, .binary, .hex, .media, .html, .unicode, .utf8, .preview]

    /// The name of the mode in the Options menu.
    internal var title: String {
        switch self {
        case .text:
            return "Text only"

        case .binary:
            return "Binary (fixed line length)"

        case .hex:
            return "Hex"

        case .media:
            return "Image/Multimedia"

        case .html:
            return "HTML text (strip tags)"

        case .unicode:
            return "Unicode"

        case .utf8:
            return "UTF-8"

        // The Mac's counterpart of the Explorer preview and of Lister plugins.
        case .preview:
            return "Quick Look Preview"
        }
    }

    /// The modes that show rows of text in the pager.
    internal var isTextual: Bool { self != .media && self != .preview }
}
