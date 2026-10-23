import Foundation

/// What a file tool reports instead of a result.
internal enum ToolError: LocalizedError, Equatable {
    /// The user (or the program quitting) cancelled the run.
    case cancelled
    /// The run failed; the message says why, for the user.
    case failed(String)

    /// The message for the user.
    internal var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The operation was cancelled."

        case .failed(let message):
            return message
        }
    }
}
