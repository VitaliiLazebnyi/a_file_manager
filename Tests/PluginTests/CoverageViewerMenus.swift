import AppKit

@testable import ViewerPlugin

/// The Lister's menus as the strip shows them, run the way a click on an entry runs them.
@MainActor
internal enum CoverageViewerMenus {
    /// The menu `title` of `pane`, filled as it is when it opens.
    internal static func menu(_ title: String, of pane: ViewerPane) -> NSMenu {
        let menu = NSMenu()
        pane.fill(menu, with: pane.menuEntries(title))
        return menu
    }

    /// The entry of menu `title` whose title begins with `entry`; nil when there is none.
    internal static func item(_ entry: String, in title: String, of pane: ViewerPane) -> NSMenuItem? {
        menu(title, of: pane).items.first { $0.title.hasPrefix(entry) }
    }

    /// Runs the entry like a click; false when it is not there or not enabled.
    @discardableResult
    internal static func run(_ entry: String, in title: String, of pane: ViewerPane) -> Bool {
        let menu = menu(title, of: pane)
        guard let index = menu.items.firstIndex(where: { $0.title.hasPrefix(entry) }), menu.items[index].isEnabled
        else {
            return false
        }
        menu.performActionForItem(at: index)
        return true
    }

    /// The pop-up buttons of the menu strip.
    internal static func stripButtons(of view: NSView) -> [NSPopUpButton] {
        view.subviews.flatMap { subview -> [NSPopUpButton] in
            (subview as? NSPopUpButton).map { [$0] } ?? stripButtons(of: subview)
        }
    }
}
