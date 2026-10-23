import AFMContracts
import AFMKernel
import AppKit

/// Registering the commands of the Mark menu, and adding them to the menus, the toolbar and the
/// options.
extension SelectionPlugin {
    /// Registers the commands of the Mark menu: one call per command, with what its handler and
    /// its `enabled` need.
    @MainActor
    private struct Registration {
        let commands: CommandRegistry
        let selections: Selections
        /// The model of the source panel.
        let model: () -> PanelModel
        /// While a directory is still arriving, "all" would silently mean "all so far".
        let isComplete: () -> Bool
        /// Whether both panels have their whole lists.
        let bothComplete: () -> Bool
        /// Whether the source panel has its whole list and an item under the cursor.
        let hasCursorItem: () -> Bool
        /// Whether the source panel has something to act on.
        let hasOperands: () -> Bool

        /// The closures keep the kernel unowned: it keeps what is registered here, which must
        /// not keep it in turn.
        init(owner: Kernel, selections: Selections) {
            unowned let kernel = owner
            commands = kernel.commands
            self.selections = selections
            let source = { kernel.panels.source.model }
            model = source
            isComplete = { source().isComplete }
            bothComplete = { kernel.panels.all.allSatisfy(\.model.isComplete) }
            hasCursorItem = { source().isComplete && source().cursorItem != nil }
            hasOperands = { source().hasOperands }
        }

        /// A command of Select group or Unselect group; `.text` gives the mask and skips the dialog.
        func group(_ command: Command, select: Bool, scope: @escaping () -> SelectionScope) {
            commands.register(command, enabled: isComplete) { [selections] argument in
                selections.group(select: select, scope: scope(), proposal: "*.*", argument: argument)
            }
        }

        /// A command of Select all or Unselect all; `.index` n takes every n-th line from the
        /// cursor.
        ///
        /// Unselecting everything is always safe, also while a directory is still arriving.
        func wholeList(_ command: Command, select: Bool, scope: @escaping () -> SelectionScope) {
            let always = { true }
            commands.register(command, enabled: select ? isComplete : always) { [selections] argument in
                selections.all(select: select, scope: scope(), step: argument.index ?? 0)
            }
        }

        /// A command of Invert selection.
        func inversion(_ command: Command, scope: @escaping () -> SelectionScope) {
            commands.register(command, enabled: isComplete) { [selections] in selections.invert(scope: scope()) }
        }

        /// A command that selects or unselects what is like the item under the cursor.
        func similar(_ command: Command, _ similarity: Selections.Similarity, select: Bool) {
            commands.register(command, enabled: hasCursorItem) { [model, selections] in
                _ = model().cursorItem.map { selections.similar(to: similarity, as: $0, select: select) }
            }
        }

        /// A command of Save selection to file.
        func save(_ command: Command, _ encoding: SelectionFile.Encoding) {
            commands.register(command, enabled: hasOperands) { [selections] argument in
                selections.saveToFile(encoding, argument: argument)
            }
        }

        /// A command of Compare directories; `.index` chooses what counts as a difference.
        func comparison(_ command: Command, withSubdirectories: Bool) {
            commands.register(command, enabled: bothComplete) { [selections] argument in
                selections.compare(
                    mode: DirectoryComparison.Mode(rawValue: argument.index ?? 0) ?? .newerOrDifferent,
                    withSubdirectories: withSubdirectories
                )
            }
        }
    }

    /// Registers the commands of the Mark menu, which `selections` carries out, and adds them to
    /// the menus, the toolbar and the options of `kernel`.
    internal static func register(_ selections: Selections, in kernel: Kernel) {
        let registration = Registration(owner: kernel, selections: selections)
        registerGroups(registration)
        registerWholeLists(registration)
        registerSimilar(registration)
        registerFilesAndComparison(registration)
        addMenus(to: kernel)
        addButtons(to: kernel)
        addPreferences(to: kernel)
    }

    /// The one default shortcut of a command.
    private static func key(_ base: Key, _ modifiers: KeyModifiers = []) -> [Shortcut] { [Shortcut(base, modifiers)] }

    /// Select group and Unselect group, and the commands of the dialog's list.
    private static func registerGroups(_ registration: Registration) {
        typealias Ids = SelectionCommands
        let (selections, model) = (registration.selections, registration.model)
        registration.group(Command(.selectGroup, "Select Group…", [.cmd("="), Shortcut(.keypadPlus)]), select: true) {
            selections.configured
        }
        registration.group(
            Command(.unselectGroup, "Unselect Group…", [.cmd("-"), Shortcut(.keypadMinus)]),
            select: false
        ) {
            .both
        }
        registration.group(Command(Ids.selectBoth, "Select Group: Files and Folders…"), select: true) { .both }
        registration.group(Command(Ids.selectFiles, "Select Group: Files Only…"), select: true) { .files }
        registration.group(Command(Ids.selectFolders, "Select Group: Folders Only…"), select: true) { .folders }
        registration.group(
            Command(Ids.selectGroupOtherChoice, "Select Group: Other Choice of Folders…", key(.keypadPlus, .shift)),
            select: true
        ) { selections.other }
        registration.group(
            Command(Ids.clearFiles, "Unselect Group: Files Only…", key(.keypadMinus, .shift)),
            select: false
        ) { .files }
        registration.group(Command(Ids.clearFolders, "Unselect Group: Folders Only…"), select: false) { .folders }
        registration.group(Command(Ids.clearAsConfigured, "Unselect Group: As Configured…"), select: false) {
            selections.configured
        }
        registration.commands.register(
            Command(Ids.selectGroupCurrentExtension, "Select Group with Current Extension…"),
            enabled: registration.isComplete
        ) {
            let ext = model().cursorFile?.ext ?? ""
            selections.group(
                select: true,
                scope: selections.configured,
                proposal: ext.isEmpty ? "*.*" : "*." + ext,
                argument: .nothing
            )
        }
        registration.commands.register(
            Command(Ids.selectFromList, "Select Group from List…"),
            enabled: registration.isComplete,
            selections.groupFromList
        )
        registration.commands.register(
            Command(Ids.defineSelectionType, "Define Selection Type…", runsDuringJobs: true),
            selections.defineType
        )
    }

    /// Select all, Unselect all and Invert selection.
    private static func registerWholeLists(_ registration: Registration) {
        typealias Ids = SelectionCommands
        let selections = registration.selections
        registration.wholeList(
            Command(.selectAll, "Select All", [.cmd("a"), Shortcut(.keypadPlus, .control)]).editing(.selectAll),
            select: true
        ) { selections.configured }
        registration.wholeList(
            Command(.unselectAll, "Unselect All", [.cmd("a", .shift), Shortcut(.keypadMinus, .control)]),
            select: false
        ) { .both }
        registration.wholeList(Command(Ids.selectAllBoth, "Select All Files and Folders"), select: true) { .both }
        registration.wholeList(Command(Ids.selectAllFiles, "Select All Files"), select: true) { .files }
        registration.wholeList(Command(Ids.selectAllFolders, "Select All Folders"), select: true) { .folders }
        registration.wholeList(
            Command(
                Ids.selectAllOtherChoice,
                "Select All: Other Choice of Folders",
                key(.keypadPlus, [.control, .shift])
            ),
            select: true
        ) { selections.other }
        registration.wholeList(
            Command(Ids.clearAllFiles, "Unselect All Files", key(.keypadMinus, [.control, .shift])),
            select: false
        ) { .files }
        registration.wholeList(Command(Ids.clearAllFolders, "Unselect All Folders"), select: false) { .folders }
        registration.wholeList(Command(Ids.clearAllAsConfigured, "Unselect All: As Configured"), select: false) {
            selections.configured
        }

        registration.inversion(Command(.invertSelection, "Invert Selection", key(.keypadMultiply))) {
            selections.configured
        }
        registration.inversion(Command(Ids.invertBoth, "Invert Selection: Files and Folders")) { .both }
        registration.inversion(Command(Ids.invertFiles, "Invert Selection: Files Only")) { .files }
        registration.inversion(Command(Ids.invertFolders, "Invert Selection: Folders Only")) { .folders }
        registration.inversion(
            Command(Ids.invertOtherChoice, "Invert Selection: Other Choice of Folders", key(.keypadMultiply, .shift))
        ) { selections.other }
    }

    /// The commands that go by the item under the cursor, and Select and go to next.
    private static func registerSimilar(_ registration: Registration) {
        typealias Ids = SelectionCommands
        let selections = registration.selections
        registration.similar(
            Command(Ids.selectCurrentExtension, "Select All With Same Extension", key(.keypadPlus, .option)),
            .ext,
            select: true
        )
        registration.similar(
            Command(Ids.unselectCurrentExtension, "Unselect All With Same Extension", key(.keypadMinus, .option)),
            .ext,
            select: false
        )
        registration.similar(Command(Ids.selectCurrentName, "Select All With Same Name"), .name, select: true)
        registration.similar(Command(Ids.unselectCurrentName, "Unselect All With Same Name"), .name, select: false)
        registration.similar(
            Command(Ids.selectCurrentNameAndExtension, "Select All With Same Name and Extension"),
            .nameAndExt,
            select: true
        )
        registration.similar(
            Command(Ids.unselectCurrentNameAndExtension, "Unselect All With Same Name and Extension"),
            .nameAndExt,
            select: false
        )
        registration.similar(Command(Ids.selectCurrentPath, "Select All in Same Folder"), .path, select: true)
        registration.similar(Command(Ids.unselectCurrentPath, "Unselect All in Same Folder"), .path, select: false)
        // `.index`: how many items from the cursor on.
        registration.commands.register(Command(Ids.select, "Select and Go to Next")) { argument in
            selections.step(select: true, count: argument.index ?? 1)
        }
        registration.commands.register(Command(Ids.unselect, "Unselect and Go to Next")) { argument in
            selections.step(select: false, count: argument.index ?? 1)
        }
    }

    /// Saving and loading, and comparing the two panels.
    private static func registerFilesAndComparison(_ registration: Registration) {
        typealias Ids = SelectionCommands
        let (commands, selections, model) = (registration.commands, registration.selections, registration.model)
        commands.register(Command(Ids.saveSelection, "Save Selection")) { model().saveSelection() }
        commands.register(
            Command(.restoreSelection, "Restore Selection", [.cmd("i", .shift), Shortcut(.keypadDivide)]),
            selections.restore
        )
        registration.save(Command(Ids.saveSelectionToFile, "Save Selection to File…"), .unicode)
        registration.save(Command(Ids.saveSelectionToFileUnicode, "Save Selection to File (Unicode)…"), .unicode)
        registration.save(Command(Ids.saveSelectionToFileANSI, "Save Selection to File (ANSI)…"), .ansi)
        commands.register(
            Command(Ids.loadSelectionFromFile, "Load Selection from File…"),
            enabled: registration.isComplete,
            parameterized: selections.loadFromFile
        )
        commands.register(
            Command(Ids.loadSelectionFromClipboard, "Load Selection from Clipboard"),
            enabled: registration.isComplete,
            selections.loadFromClipboard
        )

        registration.comparison(
            Command(Ids.compareDirectories, "Compare Directories", [.f(2, .shift)]),
            withSubdirectories: false
        )
        registration.comparison(
            Command(Ids.compareDirectoriesWithSubdirectories, "Compare Directories, Mark Missing Folders Too"),
            withSubdirectories: true
        )
        commands.register(
            Command(Ids.markNewerHideSame, "Mark Newer, Hide Same Files"),
            enabled: registration.bothComplete,
            checked: { selections.shows(.comparison, in: model()) },
            selections.markNewerHideSame
        )
    }

    /// Adds the commands to the menus.
    private static func addMenus(to kernel: Kernel) {
        typealias Ids = SelectionCommands
        kernel.menus.add([.selectGroup, .unselectGroup, Ids.selectFromList, Ids.defineSelectionType], to: .markGroups)
        kernel.menus.add([.selectAll, .unselectAll, .invertSelection, Ids.selectCurrentExtension], to: .markAll)
        kernel.menus.add(
            [
                Ids.saveSelection, .restoreSelection, Ids.saveSelectionToFile, Ids.loadSelectionFromFile,
                Ids.loadSelectionFromClipboard
            ],
            to: .markStore
        )
        kernel.menus.add(
            [Ids.compareDirectories, Ids.compareDirectoriesWithSubdirectories, Ids.markNewerHideSame],
            to: .markCompare
        )
    }

    /// Adds the buttons of the toolbar.
    private static func addButtons(to kernel: Kernel) {
        kernel.toolbar.add(
            .selectGroup,
            symbol: "plus.square",
            group: 50,
            hint: "Select the files that match a pattern, such as *.jpg."
        )
        kernel.toolbar.add(
            .unselectGroup,
            symbol: "minus.square",
            group: 50,
            hint: "Unselect the files that match a pattern."
        )
        kernel.toolbar.add(
            .invertSelection,
            symbol: "circle.lefthalf.filled",
            group: 50,
            hint: "Select what is not selected, and unselect what is."
        )
        kernel.toolbar.add(
            SelectionCommands.compareDirectories,
            symbol: "rectangle.split.2x1",
            group: 50,
            hint: "Select the files that differ between the two panels."
        )
        kernel.toolbar.setSymbol("checkmark.square", for: .selectAll)
        kernel.toolbar.setSymbol("square", for: .unselectAll)
        kernel.toolbar.setSymbol("arrow.uturn.backward.square", for: .restoreSelection)
        kernel.toolbar.setSymbol("clock.arrow.2.circlepath", for: SelectionCommands.markNewerHideSame)
    }

    /// Adds the options page of the Mark menu.
    private static func addPreferences(to kernel: Kernel) {
        kernel.preferences.add(
            PreferencePage(
                title: "Selection",
                preferences: [
                    Preference(
                        SelectionStore.marksFoldersKey,
                        "Num +, Ctrl+Num + and Num * also select folders",
                        .flag(default: true)
                    ),
                    Preference(
                        SelectionStore.oneHourKey,
                        "Compare directories: times exactly one hour apart are equal",
                        .flag(default: false)
                    )
                ]
            )
        )
    }
}
