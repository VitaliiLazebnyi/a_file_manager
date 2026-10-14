import XCTest

/// What the tests of the package write as Swift Testing's `#expect`, which a UI test bundle
/// cannot import.
internal enum Check {
    /// Records a failure with `message` unless `condition` holds.
    internal static func that(_ condition: Bool, _ message: String) {
        if !condition { XCTFail(message) }
    }
}
