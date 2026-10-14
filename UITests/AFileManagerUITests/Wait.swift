import Foundation
import XCTest

/// Waits that end as soon as their condition holds.
///
/// Each waits for at most `AppSession.patience`, and one that runs out records a failure. There
/// are no fixed pauses in the UI tests.
@MainActor
internal enum Wait {
    /// Waits until `element` exists.
    internal static func forElement(_ element: XCUIElement) {
        if !element.waitForExistence(timeout: AppSession.patience) {
            XCTFail("timed out waiting for \(element)")
        }
    }

    /// Waits until `element` has `value` at `keyPath`.
    internal static func until<Value: Equatable>(
        _ element: XCUIElement,
        _ keyPath: KeyPath<XCUIElement, Value>,
        is value: Value
    ) {
        if !element.wait(for: keyPath, toEqual: value, timeout: AppSession.patience) {
            XCTFail("timed out waiting for \(element) to have \(keyPath) == \(value)")
        }
    }

    /// Waits until `condition` holds, asking again each time XCTest looks (it does so over and
    /// over while it waits).
    internal static func until(_ description: String, _ condition: @escaping @MainActor () -> Bool) {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = description
        if XCTWaiter().wait(for: [expectation], timeout: AppSession.patience) != .completed {
            XCTFail("timed out waiting until \(description)")
        }
    }
}
