@testable import AFMKernel

/// The items the panel was last given, which its list must hold (in any order).
internal struct ExpectedListing {
    /// The items as they were handed to the panel.
    internal let items: [FileItem]

    /// The listing of `items`.
    internal init(_ items: [FileItem]) {
        self.items = items
    }
}
