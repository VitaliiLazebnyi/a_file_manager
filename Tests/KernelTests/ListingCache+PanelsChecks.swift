import AFMKernel
import Foundation

/// What a test asks the listing cache about remembered folders, read without hidden files.
extension ListingCache {
    /// Whether every one of these folders is remembered.
    internal func remembers(_ folders: URL...) -> Bool {
        folders.allSatisfy { age(of: $0, showHidden: false) != nil }
    }

    /// Whether none of these folders is remembered.
    internal func forgets(_ folders: URL...) -> Bool {
        folders.allSatisfy { age(of: $0, showHidden: false) == nil }
    }
}
