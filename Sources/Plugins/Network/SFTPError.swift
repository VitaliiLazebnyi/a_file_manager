public import Foundation

/// An error status of the SFTP server.
public struct SFTPError: LocalizedError, Sendable {
    /// The status of a read or a listing that reached the end.
    internal static let endOfFile: UInt32 = 1
    /// The status of a path where nothing is.
    internal static let noSuchFile: UInt32 = 2

    /// The status code (draft-ietf-secsh-filexfer-02 › Responses from the Server).
    public let code: UInt32
    /// The text the server sent with the status; may be empty.
    public let message: String

    /// What the server said, or else what its code means.
    public var errorDescription: String? {
        if !message.isEmpty, message != "Failure" {
            return "The server answered: \(message)"
        }
        switch code {
        case 2:
            return "The file or folder does not exist on the server."

        case 3:
            return "The server does not permit this."

        case 8:
            return "The server does not support this operation."

        default:
            return "The server reported an error (\(code))."
        }
    }
}
