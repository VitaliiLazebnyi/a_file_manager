import AFMKernel
import AppKit

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
internal final class ThumbnailStore {
    /// A key of the cache, which takes objects only.
    private final class CacheKey: NSObject {
        /// The key of the picture (`ThumbnailStore.key`).
        let key: String

        override var hash: Int { key.hashValue }

        init(_ key: String) {
            self.key = key
        }

        override func isEqual(_ object: Any?) -> Bool {
            (object as? CacheKey)?.key == key
        }
    }

    /// The memory the pictures may take, counted in pixels of 4 bytes. A 256 pt tile on a
    /// Retina screen is 1 MB, so the count alone would allow gigabytes.
    internal static let costLimit = 192 * 1_024 * 1_024

    /// Where the pictures come from.
    internal var source: any ThumbnailSource
    /// Called on the main thread with the name of the entry whose picture arrived.
    internal var onArrival: ((String) -> Void)?
    /// The requests under way, by key. Each has a token of its own: the answer of a request that
    /// was given up must not be taken for the answer of a newer request for the same file.
    internal private(set) var running: [String: (token: UInt64, cancel: () -> Void)] = [:]

    private let cache = NSCache<CacheKey, NSImage>()
    private var lastToken: UInt64 = 0
    /// Files that have no picture of their own; they are not asked for again.
    private var without: Set<String> = []

    /// An empty store whose pictures come from `source`.
    internal init(source: any ThumbnailSource) {
        self.source = source
        cache.countLimit = 3_000
        cache.totalCostLimit = Self.costLimit
    }

    /// What a picture costs the cache: its size in bytes as pixels.
    internal static func cost(of image: NSImage) -> Int {
        let pixels = image.representations.map { ($0.pixelsWide, $0.pixelsHigh) }.max { $0.0 * $0.1 < $1.0 * $1.1 }
        if let pixels, pixels.0 > 0, pixels.1 > 0 {
            return pixels.0 * pixels.1 * 4
        }
        return max(1, Int(image.size.width * image.size.height) * 4)
    }

    /// Identifies the picture of an entry as it was listed, at one size: a file that changed
    /// gets a new picture.
    internal static func key(for item: FileItem, side: CGFloat) -> String {
        "\(item.url.absoluteString)|\(item.size)|\(item.modified.timeIntervalSince1970)|\(Int(side))"
    }

    /// The picture, when it is there; otherwise nil, and it is on its way unless the file has none.
    internal func image(for item: FileItem, side: CGFloat, scale: CGFloat) -> NSImage? {
        let key = Self.key(for: item, side: side)
        if let image = cache.object(forKey: CacheKey(key)) {
            return image
        }
        guard running[key] == nil, !without.contains(key) else {
            return nil
        }
        let name = item.name
        lastToken += 1
        let token = lastToken
        let cancel = source.thumbnail(for: item.url, side: side, scale: scale) { [weak self] image in
            MainLoop.perform { [weak self] in self?.take(image, for: key, name: name, token: token) }
        }
        running[key] = (token, cancel)
        return nil
    }

    /// Gives up the requests for everything but `keys`: the tiles that are on screen now.
    internal func keepOnly(_ keys: Set<String>) {
        for (key, request) in running where !keys.contains(key) {
            request.cancel()
            running[key] = nil
        }
    }

    /// Gives up every request and forgets which files have no picture: the panel shows another folder.
    internal func reset() {
        keepOnly([])
        without = []
    }

    /// The answer of the request `token` for `key`; an answer for a request that was given up
    /// (or given up and made again) is of no interest.
    private func take(_ image: NSImage?, for key: String, name: String, token: UInt64) {
        guard running[key]?.token == token else {
            return
        }
        running[key] = nil
        if let image {
            cache.setObject(image, forKey: CacheKey(key), cost: Self.cost(of: image))
            onArrival?(name)
        } else {
            without.insert(key)
        }
    }

    deinit {
        // Nothing to release: an answer that comes later finds the store gone.
    }
}
