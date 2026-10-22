import AppKit

@testable import AFMShell

/// The object behind the keys of a menu bar, for the tests that count what it looks at.
extension MenuBuilder {
    /// The object that answers for the keys of a menu bar built by `mainMenu`: the delegate of
    /// the plugins' menus; nil when the bar has none.
    internal static func keyAnswers(of main: NSMenu) -> MenuKeys? {
        main.items.lazy.compactMap { $0.submenu?.delegate as? MenuKeys }.first
    }
}
