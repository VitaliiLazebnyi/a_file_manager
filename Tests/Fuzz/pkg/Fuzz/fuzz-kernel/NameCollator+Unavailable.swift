@testable import AFMKernel

/// A collator without the system's library, as sorting falls back on when ICU is missing.
extension NameCollator {
    /// Names ordered by their lowercase forms.
    internal static let unavailable = NameCollator(identifier: "", numeric: false, library: nil)
}
