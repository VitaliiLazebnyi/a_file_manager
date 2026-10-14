import Foundation

/// Lets go of large lists away from the thread that used them: freeing a million entries
/// takes a tenth of a second and more, which the main thread does not have.
internal enum Discard: Sendable {
    /// Handed from the thread that lets go to the one that releases.
    ///
    /// Unchecked: the thread that made it lets go of it without touching the list, so one thread at a time uses it.
    private final class Box<Element>: @unchecked Sendable {
        private var items: [Element]

        init(_ items: [Element]) { self.items = items }

        func empty() { items.removeAll() }

        deinit {
            // Nothing to release but the list, which `empty` has let go of already.
        }
    }

    /// Lists shorter than this are not worth the trip.
    internal static let threshold = 20_000

    /// Empties `items`; if the list is long, the memory is released on a background thread
    /// (when nobody else holds the list, otherwise whoever lets go last releases it).
    internal static func later<Element>(_ items: inout [Element]) {
        guard items.count >= threshold else {
            items = []
            return
        }
        let box = Box(items)
        items = []
        KernelThreads.shared.run { box.empty() }
    }
}
