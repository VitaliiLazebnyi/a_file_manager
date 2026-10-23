import Foundation

/// The dates inside pictures (`[T4]`), kept for as long as a session lives: a list that is
/// only put in another order does not read its files again.
///
/// Safe to use from several threads.
///
/// Unchecked `Sendable`: `dates` is guarded by `lock`.
internal final class ContentDateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [URL: Date?] = [:]

    /// The date in the picture at `url` (`ContentDate.read`), read once.
    internal func date(of url: URL) -> Date? {
        lock.lock()
        let known = dates[url]
        lock.unlock()
        if let known {
            return known
        }
        let found = ContentDate.read(url)
        lock.lock()
        dates[url] = .some(found)
        lock.unlock()
        return found
    }

    deinit {
        // Nothing to release.
    }
}
