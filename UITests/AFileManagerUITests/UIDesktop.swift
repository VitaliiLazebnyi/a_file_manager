import XCTest

/// What the UI tests of the system adapters do with the program on the desktop: its menus, its
/// windows, and the panels of the system it shows.
@MainActor
internal struct UIDesktop {
    /// The program.
    internal let app: XCUIApplication

    /// The panels and sheets of the system on screen (open, save, the sharing picker), and the
    /// program's own alerts.
    internal var panels: Int {
        app.sheets.count + app.dialogs.count
    }

    /// The desktop of the program of `session`.
    internal init(_ session: AppSession) {
        app = session.app
    }

    /// Chooses a menu item of the menu bar: `path` is the menu, the submenus and the item, each
    /// looked for in the one before it (several menus have a "More").
    internal func menu(_ path: String...) {
        var current = app.menuBars.firstMatch.menuBarItems[path[0]]
        Wait.forElement(current)
        current.click()
        for title in path.dropFirst() {
            current = current.menuItems[title].firstMatch
            Wait.forElement(current)
            current.click()
        }
    }

    /// Chooses the `index`th item called `title` of the menu `menu` (two plugins may give an
    /// item the same title).
    internal func menu(_ menu: String, item title: String, number index: Int) {
        let top = app.menuBars.firstMatch.menuBarItems[menu]
        Wait.forElement(top)
        top.click()
        let item = top.menuItems.matching(NSPredicate(format: "title == %@", title)).element(boundBy: index)
        Wait.forElement(item)
        item.click()
    }

    /// The program's window whose title starts with `prefix`; a window shown as a modal dialog
    /// is a dialog to the accessibility interface.
    internal func window(titled prefix: String) -> XCUIElement {
        let kinds = [XCUIElement.ElementType.window, .dialog].map(\.rawValue)
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType IN %@ AND title BEGINSWITH %@", kinds, prefix))
            .firstMatch
    }

    /// Waits until an open panel is on screen, chooses `path` in it (Go to Folder, then Open)
    /// and waits until it has gone.
    ///
    /// `what` names the panel in a failure.
    internal func choose(_ path: String, in what: String) {
        let desktop = self
        Wait.until("\(what) is shown") { desktop.panels > 0 }
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(path + "\n")
        app.typeKey(.return, modifierFlags: [])
        Wait.until("\(what) has gone") { desktop.panels == 0 }
    }

    /// Waits until a panel or a sheet is on screen, presses Esc and waits until it has gone.
    ///
    /// `what` names it in a failure.
    internal func cancelPanel(_ what: String) {
        let desktop = self
        Wait.until("\(what) is shown") { desktop.panels > 0 }
        app.typeKey(.escape, modifierFlags: [])
        Wait.until("\(what) has gone") { desktop.panels == 0 }
    }
}
