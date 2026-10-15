import AppKit

/// Makes the picture of one file.
@MainActor
internal protocol ThumbnailSource: AnyObject {
    /// Asks for the picture of the file at `url`, `side` points square at `scale` pixels per
    /// point. `completion` may be called on any thread, with nil when the file has no picture of
    /// its own. The returned function gives the request up.
    func thumbnail(
        for url: URL,
        side: CGFloat,
        scale: CGFloat,
        completion: @escaping @Sendable (NSImage?) -> Void
    ) -> () -> Void
}
