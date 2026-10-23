import AFMContracts
import AFMKernel

/// Where the plugin's commands are offered, and its preference page.
extension MacIntegrationPlugin {
    /// Puts the plugin's commands into the menus, the context menu and the toolbar, and adds the
    /// preference page of the editor; main thread, once, while the plugin starts.
    internal static func addMenus(in kernel: Kernel) {
        addToMenus(kernel.menus)
        addToToolbar(kernel.toolbar)
        kernel.preferences.add(
            PreferencePage(
                title: "Edit (F4)",
                preferences: [
                    Preference(
                        Self.editorKey,
                        "Editor (application name, path or bundle identifier):",
                        .text(default: Self.defaultEditor)
                    )
                ]
            )
        )
    }

    /// The menu bar's Files menu, Configuration › Customize, and the context menu of a file.
    private static func addToMenus(_ menus: MenuRegistry) {
        let macSection = MenuSection(.files, order: 12)
        menus.add([.edit], to: .filesOpen)
        menus.add(
            [Self.openWith, Self.openWithDefault, Self.quickLook],
            to: macSection
        )
        menus.add(
            [
                .revealInFinder, Self.share, Self.editTags,
                Self.copyAsPathname
            ],
            to: .filesTools
        )
        menus.add([Self.chooseEditor], to: .configurationCustomize)
        menus.addToContextMenu([.edit], in: .open, onItemOnly: true)
        menus.addToContextMenu([.revealInFinder], in: .tools)
        menus.addToContextMenu(
            [
                Self.openWith, Self.quickLook, Self.share,
                Self.editTags, Self.copyAsPathname
            ],
            in: ContextMenuSection(order: 55),
            onItemOnly: true
        )
    }

    /// The toolbar's Quick Look and Share buttons, and the symbols of the other commands.
    private static func addToToolbar(_ toolbar: ToolbarRegistry) {
        toolbar.add(
            Self.quickLook,
            symbol: "eye",
            group: 60,
            hint: "Preview the selected file with macOS Quick Look."
        )
        toolbar.add(
            Self.share,
            symbol: "square.and.arrow.up",
            group: 60,
            hint: "Share the selected files: AirDrop, Mail, Messages and more."
        )
        toolbar.setSymbol("tag", for: Self.editTags)
        toolbar.setSymbol("arrow.up.forward.app", for: Self.openWith)
        toolbar.setSymbol("folder", for: .revealInFinder)
        toolbar.setSymbol("pencil", for: .edit)
    }
}
