import AFMKernel
import AppKit
import QuickLookThumbnailing

/// Makes the picture of one file. `completion` may be called on any thread, with nil when the
/// file has no picture of its own. The returned function gives the request up.
protocol ThumbnailSource: AnyObject {
    func thumbnail(
        for url: URL, side: CGFloat, scale: CGFloat, completion: @escaping @Sendable (NSImage?) -> Void
    ) -> () -> Void
}

/// Thumbnails from the system's Quick Look, which makes them in its own processes and threads
/// and keeps the main thread out of it.
final class QuickLookThumbnails: ThumbnailSource {
    func thumbnail(
        for url: URL, side: CGFloat, scale: CGFloat, completion: @escaping @Sendable (NSImage?) -> Void
    ) -> () -> Void {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            completion(representation?.nsImage)
        }
        return { QLThumbnailGenerator.shared.cancel(request) }
    }
}

/// The pictures of the Thumbnails view of one panel (spec 03 › Thumbnails).
///
/// The view asks for the picture of a tile when it draws it. A picture that is not there yet
/// is requested from the source, which works in the background; the tile shows the file's icon
/// until `onArrival` says the picture has come. Pictures are kept in a cache the system may
/// empty under memory pressure. Requests for tiles that were scrolled out of sight are
/// cancelled (`keepOnly`), so a fast scroll through a large folder leaves no queue behind.
///
/// **Threading.** Main thread only; the source's answer is brought back to the main thread.
@MainActor
final class ThumbnailStore {
    var source: any ThumbnailSource
    private let cache = NSCache<NSString, NSImage>()
    /// The requests under way, by key. Each has a token of its own: the answer of a request that
    /// was given up must not be taken for the answer of a newer request for the same file.
    private var running: [String: (token: UInt64, cancel: () -> Void)] = [:]
    private var lastToken: UInt64 = 0
    /// Files that have no picture of their own; they are not asked for again.
    private var without: Set<String> = []
    /// Called on the main thread with the name of the entry whose picture arrived.
    var onArrival: ((String) -> Void)?

    /// The memory the pictures may take, counted in pixels of 4 bytes. A 256 pt tile on a
    /// Retina screen is 1 MB, so the count alone would allow gigabytes.
    static let costLimit = 192 * 1_024 * 1_024

    init(source: any ThumbnailSource = QuickLookThumbnails()) {
        self.source = source
        cache.countLimit = 3_000
        cache.totalCostLimit = Self.costLimit
    }

    /// What a picture costs the cache: its size in bytes as pixels.
    static func cost(of image: NSImage) -> Int {
        let pixels = image.representations.map { ($0.pixelsWide, $0.pixelsHigh) }.max { $0.0 * $0.1 < $1.0 * $1.1 }
        if let pixels, pixels.0 > 0, pixels.1 > 0 { return pixels.0 * pixels.1 * 4 }
        return max(1, Int(image.size.width * image.size.height) * 4)
    }

    /// Identifies the picture of an entry as it was listed, at one size: a file that changed
    /// gets a new picture.
    static func key(for item: FileItem, side: CGFloat) -> String {
        "\(item.url.absoluteString)|\(item.size)|\(item.modified.timeIntervalSince1970)|\(Int(side))"
    }

    /// The picture, when it is there; otherwise nil, and it is on its way unless the file has none.
    func image(for item: FileItem, side: CGFloat, scale: CGFloat) -> NSImage? {
        MainThread.assert("The thumbnails")
        let key = Self.key(for: item, side: side)
        if let image = cache.object(forKey: key as NSString) { return image }
        guard running[key] == nil, !without.contains(key) else { return nil }
        let name = item.name
        lastToken += 1
        let token = lastToken
        let cancel = source.thumbnail(for: item.url, side: side, scale: scale) { [weak self] image in
            MainLoop.perform { [weak self] in
                // An answer for a request that was given up (or given up and made again) is of no interest.
                guard let self, self.running[key]?.token == token else { return }
                self.running[key] = nil
                if let image {
                    self.cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
                    self.onArrival?(name)
                } else {
                    self.without.insert(key)
                }
            }
        }
        running[key] = (token, cancel)
        return nil
    }

    /// The number of pictures being made right now.
    var runningCount: Int { running.count }

    /// Gives up the requests for everything but `keys`: the tiles that are on screen now.
    func keepOnly(_ keys: Set<String>) {
        for (key, request) in running where !keys.contains(key) {
            request.cancel()
            running[key] = nil
        }
    }

    /// Gives up every request and forgets which files have no picture: the panel shows another folder.
    func reset() {
        keepOnly([])
        without = []
    }
}
