import AFMContracts
import AFMKernel
import Foundation

/// The parts of `start(in:)`: what the plugin adds to the kernel's registries.
extension FilePropertiesPlugin {
    /// The commands, each enabled where it can do something; `actions` does the work.
    internal static func registerCommands(in owner: Kernel, actions: PropertyActions) {
        // The kernel keeps these closures; they must not keep it in turn.
        unowned let kernel = owner
        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let hasOperands = { model().hasOperands }
        let isWritable = { kernel.fileSystems.capabilities(for: model().directory).contains(.write) }
        let isLocal = { model().directory.isFileURL }

        commands.register(
            Command(.setAttributes, "Change Attributes…"),
            enabled: { hasOperands() && isWritable() },
            parameterized: actions.changeAttributes
        )
        commands.register(
            Command(.properties, "Properties…", [Shortcut(.returnKey, .option), .cmd("i")]),
            enabled: { model().isListed },
            actions.showProperties
        )
        commands.register(
            Command(.occupiedSpace, "Calculate Occupied Space…", [Shortcut(.character("l"), .control)]),
            enabled: hasOperands,
            actions.calculateOccupiedSpace
        )
        commands.register(
            Command(
                .countDirectoryContents,
                "Calculate All Folder Sizes",
                [Shortcut(.returnKey, [.option, .shift])]
            ),
            enabled: { model().isComplete && model().totals.totalFolders > 0 },
            actions.countDirectoryContents
        )
        commands.register(
            Command(.editComment, "Edit Comment…", [Shortcut(.character("z"), .control)]),
            enabled: { isWritable() && (model().cursorItem != nil || model().parentTarget != nil) },
            actions.editComment
        )
        commands.register(
            Command(.createShortcut, "Create Link…", [.f(5, [.control, .shift])]),
            enabled: { hasOperands() && isLocal() },
            actions.createLinks
        )
        commands.register(
            Command(.showLinkTarget, "Show Link Target"),
            enabled: { model().cursorItem?.url.isFileURL ?? false },
            actions.showCursorLinkTarget
        )
        commands.register(
            Command(.finderInfo, "Finder Info", runsDuringJobs: true),
            enabled: { isLocal() && model().isListed },
            actions.showFinderInfoOfOperands
        )
    }

    /// The entries of the Files menu and the context menu, and the toolbar buttons and symbols.
    internal static func addMenusAndButtons(in kernel: Kernel) {
        kernel.menus.add(
            [.setAttributes, .properties, .finderInfo, .occupiedSpace, .countDirectoryContents, .editComment],
            to: .filesProperties
        )
        kernel.menus.add([.createShortcut, .showLinkTarget], to: .filesAdvanced)
        kernel.menus.addToContextMenu(
            [.setAttributes, .editComment, .createShortcut],
            in: .properties,
            onItemOnly: true
        )
        kernel.menus.addToContextMenu([.occupiedSpace, .properties], in: .properties)
        kernel.toolbar.add(
            .properties,
            symbol: "info.circle",
            group: 60,
            hint: "Show the properties of the selected file or folder: size, dates, permissions."
        )
        kernel.toolbar.add(
            .occupiedSpace,
            symbol: "chart.pie",
            group: 60,
            hint: "Calculate how much space the selected folders take, with everything in them."
        )
        kernel.toolbar.setSymbol("slider.horizontal.3", for: .setAttributes)
        kernel.toolbar.setSymbol("text.bubble", for: .editComment)
        kernel.toolbar.setSymbol("link", for: .createShortcut)
    }

    /// The page of the plugin in the preferences.
    internal static func addPreferences(in kernel: Kernel) {
        kernel.preferences.add(
            PreferencePage(
                title: "File properties",
                preferences: [
                    Preference(
                        Settings.linkKind,
                        "Create Link proposes:",
                        .choice(LinkKind.allCases.map(\.title), default: LinkKind.symbolic.rawValue)
                    ),
                    Preference(
                        Settings.relativeLinks,
                        "Symbolic links point to relative paths",
                        .flag(default: false)
                    ),
                    Preference(
                        Settings.selectMeasured,
                        "Calculate Occupied Space selects the measured folders",
                        .flag(default: true)
                    ),
                    Preference(Settings.hideCommentFile, "Hide the comment file descript.ion", .flag(default: true))
                ]
            )
        )
    }
}
