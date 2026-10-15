import AppKit

@testable import AFMShell

/// A thumbnail source that answers when the test says so, from a background thread as Quick
/// Look does, and notes what was asked for and given up.
@MainActor
internal final class PanelScriptedThumbnails: ThumbnailSource {
    /// The answers that are still to come, by file name.
    internal var pending: [String: @Sendable (NSImage?) -> Void] = [:]
    /// The files asked for, in order.
    internal var requested: [String] = []
    /// The files whose requests were given up, in order.
    internal var cancelled: [String] = []

    /// A source that has been asked nothing.
    internal init() {
        // Nothing asked yet.
    }

    /// Notes the request; the answer waits for `answer`.
    internal func thumbnail(
        for url: URL,
        side _: CGFloat,
        scale _: CGFloat,
        completion: @escaping @Sendable (NSImage?) -> Void
    ) -> () -> Void {
        let name = url.lastPathComponent
        requested.append(name)
        pending[name] = completion
        return { [weak self] in
            self?.cancelled.append(name)
            self?.pending[name] = nil
        }
    }

    /// Answers the request for `name` with `image`, from a background thread.
    internal func answer(_ name: String, with image: NSImage?) {
        guard let completion = pending.removeValue(forKey: name) else {
            return
        }
        Thread.detachNewThread { completion(image) }
    }

    deinit {
        // Nothing to release.
    }
}
