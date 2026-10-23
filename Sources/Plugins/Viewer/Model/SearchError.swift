import Foundation

/// Why what was typed into the Find dialog cannot be searched for.
internal enum SearchError: LocalizedError, Equatable {
    /// The regular expression does not compile; the reason the system gives.
    case badExpression(String)
    /// The text is not a hex string.
    case badHex(String)
    /// Nothing was typed.
    case empty

    /// The sentence the viewer shows.
    internal var errorDescription: String? {
        switch self {
        case .empty:
            return "There is nothing to search for."

        case .badHex(let text):
            return "\"\(text)\" is not a hex string. Write bytes as 00 FF 12, literal text in quotes: \"PK\"0102."

        case .badExpression(let reason):
            return "The regular expression cannot be used: \(reason)"
        }
    }
}
