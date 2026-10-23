import Foundation

/// What can go wrong in a run beyond what the file systems report.
internal enum RenameRunError: LocalizedError {
    /// A file that was parked could go neither on to its new name nor back to its old one: the
    /// temporary name and the reason.
    case leftUnderTemporaryName(String, String)

    /// The message shown for the error.
    internal var errorDescription: String? {
        switch self {
        case .leftUnderTemporaryName(let name, let reason):
            return "The file was left under the temporary name \(name): \(reason)"
        }
    }
}
