public import Foundation

/// A mount or an eject that failed, with the message the user is shown.
public struct VolumeError: LocalizedError, Sendable {
    /// What went wrong, in a sentence for the user.
    public let message: String

    /// `message`, which is what the error alert shows.
    public var errorDescription: String? { message }

    /// An error that shows `message`.
    public init(message: String) {
        self.message = message
    }
}
