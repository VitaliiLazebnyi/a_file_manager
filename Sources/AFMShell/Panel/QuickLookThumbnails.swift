import AppKit
import QuickLookThumbnailing

/// Thumbnails from the system's Quick Look, which makes them in its own processes and threads
/// and keeps the main thread out of it.
internal final class QuickLookThumbnails: ThumbnailSource {
    /// The system's thumbnails.
    internal init() {
        // Quick Look keeps everything itself.
    }

    /// Asks Quick Look for the file's picture (`ThumbnailSource`).
    internal func thumbnail(
        for url: URL,
        side: CGFloat,
        scale: CGFloat,
        completion: @escaping @Sendable (NSImage?) -> Void
    ) -> () -> Void {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            completion(representation?.nsImage)
        }
        return { QLThumbnailGenerator.shared.cancel(request) }
    }

    deinit {
        // Nothing to release.
    }
}
