import Foundation
import XCTest

/// Finding the parts of a file list.
extension XCUIElement {
    /// The row of a file list whose name column shows `name` (a file's name without its
    /// extension, which has a column of its own).
    @MainActor
    internal func row(named name: String) -> XCUIElement {
        tableRows.containing(NSPredicate(format: "value == %@", name)).firstMatch
    }
}
