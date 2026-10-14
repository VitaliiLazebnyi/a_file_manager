import Foundation

/// How deep the calls of a walk through a tree of folders are nested on the current thread.
///
/// For walks that call themselves once per level (`totalSizeByListing`), so that they can stop nesting before a
/// thread's stack is used up.
internal enum TreeWalk: Sendable {
    /// Calls nested deeper than this on one thread go on without nesting.
    internal static let deepestNesting = 32
    /// Levels below which a walk that no longer nests gives up: no real tree is that deep.
    internal static let deepestTree = 1_000

    /// Where each thread keeps its count.
    private static let key: pthread_key_t = {
        var made = pthread_key_t()
        pthread_key_create(&made, nil)
        return made
    }()

    /// The number of walk calls under way on this thread, one inside the other.
    internal static var nesting: Int {
        get { Int(bitPattern: pthread_getspecific(key)) }
        set { pthread_setspecific(key, UnsafeRawPointer(bitPattern: newValue)) }
    }
}
