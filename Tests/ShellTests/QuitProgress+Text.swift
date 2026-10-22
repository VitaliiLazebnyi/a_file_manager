import AppKit

@testable import AFMShell

/// What the quitting window says, for the tests that follow it.
extension QuitProgress {
    /// The first line of the window.
    internal var text: String { heading.stringValue }
}
