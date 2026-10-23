import AFMKernel

/// A flag that is set when any of its parents is, for work that has a stop of its own and also
/// ends with the document or the pane it belongs to.
///
/// Keep the value for as long as the work runs; letting go of it unhooks the flag from its parents.
///
/// Immutable after `init`; the tokens are only held, never used.
internal final class LinkedCancellation: @unchecked Sendable {
    /// The flag the work looks at: set by its own stop, or by any of the parents.
    internal let flag = CancellationFlag()
    private let tokens: [AnyObject]

    /// A new flag, set as soon as one of `parents` is (at once when one is set already).
    internal init(_ parents: CancellationFlag...) {
        let child = flag
        tokens = parents.map { parent in parent.onCancel { [weak child] in child?.cancel() } }
    }

    deinit {
        // Nothing to release: dropping the tokens unhooks the flag from its parents.
    }
}
