/// How file contents travel (spec 11 › Transfer modes).
///
/// The raw value is the index stored in the settings and the row of the choice the user picks from.
public enum TransferMode: Int, CaseIterable, Sendable {
    /// Text for the file types listed in the preferences, binary for the rest.
    case automatic = 2
    /// Byte for byte.
    case binary = 0
    /// Line ends are converted between the server's and the Mac's.
    case text = 1

    /// The modes in the order of their raw values, the order in which the user picks one.
    public static let allCases: [Self] = [.binary, .text, .automatic]

    /// The name of the mode in the preferences and in the choice of a transfer mode.
    public var title: String {
        switch self {
        case .binary:
            return "Binary (archives, doc etc.)"

        case .text:
            return "Text (plain text, html, etc.)"

        case .automatic:
            return "Automatic"
        }
    }
}
