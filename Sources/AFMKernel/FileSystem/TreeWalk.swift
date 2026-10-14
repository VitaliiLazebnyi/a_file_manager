import Foundation

/// How deep the calls of a walk through a tree of folders are nested on the current thread.
/// For walks that call themselves once per level (`totalSizeByListing`), so that they can
/// stop nesting before a thread's stack is used up.
enum TreeWalk: Sendable {
    /// Calls nested deeper than this on one thread go on without nesting.
    static let deepestNesting = 32
    /// Levels below which a walk that no longer nests gives up: no real tree is that deep.
    static let deepestTree = 1_000

    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    /// The number of walk calls under way on this thread, one inside the other.
    static var nesting: Int {
        get { Int(bitPattern: pthread_getspecific(key)) }
        set { pthread_setspecific(key, UnsafeRawPointer(bitPattern: newValue)) }
    }
}
