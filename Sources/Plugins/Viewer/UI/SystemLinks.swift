import AppKit

/// Opens links in the programs the system has for them: the browser, the mail program.
@MainActor
internal struct SystemLinks: LinkOpening {
    /// Hands `url` to the system.
    internal func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
