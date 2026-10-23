import AFMContracts
public import AFMKernel
import AppKit
import Foundation

/// Copy, move, rename, new folder, new file and delete (spec 07 › File operations), the
/// Copy/Delete and Log file pages of the configuration, and the operation log.
public final class FileOperationsPlugin: Plugin {
    /// When the commands are offered, asked of the panels whenever a menu or a button is drawn.
    ///
    /// Main thread. The kernel is held unowned: it keeps the commands, and through them these.
    @MainActor
    private struct Conditions {
        /// The model of the source panel.
        let source: () -> PanelModel
        /// Whether the source panel has something to work on.
        let hasOperands: () -> Bool
        /// Whether the folder the source panel shows can be changed at all.
        let isWritable: () -> Bool
        /// Whether something new can be made in the folder a panel shows: not where entries
        /// can only be removed (a list of files from anywhere, `.removeOnly`).
        let takesNew: (PanelModel) -> Bool

        /// Whether the operands can be moved, renamed or deleted.
        var canMove: () -> Bool {
            { [hasOperands, isWritable] in hasOperands() && isWritable() }
        }

        /// Whether the item under the cursor can be renamed.
        var canRename: () -> Bool {
            { [source, isWritable] in source().cursorItem != nil && isWritable() }
        }

        init(_ owner: Kernel) {
            unowned let kernel = owner
            let sourceModel = { kernel.panels.source.model }
            source = sourceModel
            hasOperands = { sourceModel().hasOperands }
            isWritable = { kernel.fileSystems.capabilities(for: sourceModel().directory).contains(.write) }
            takesNew = { model in
                let capabilities = kernel.fileSystems.capabilities(for: model.directory)
                return capabilities.contains(.write) && !capabilities.contains(.removeOnly)
            }
        }
    }

    /// The plugin's name, for the log.
    public let name = "File operations"
    /// The behaviour behind the commands, made when the plugin starts.
    private var operations: FileOperations?
    /// The text of the clipboard, for `[X]` in new names.
    private let clipboard: @Sendable () -> String?

    /// The plugin, reading the system's clipboard.
    public convenience init() {
        self.init { NSPasteboard.general.string(forType: .string) }
    }

    /// The plugin reading the clipboard through `clipboard`; tests bring a text of their own.
    internal init(clipboard: @escaping @Sendable () -> String?) {
        self.clipboard = clipboard
    }

    /// Copy and move, with their dialogs and without (spec 07 › Copy dialog).
    ///
    /// `.text` carries the dialog's options as switches: `/V1 O2 T="/tmp/" W="*.txt" G` (17 › Commands with
    /// parameters).
    private static func registerTransfers(
        in commands: CommandRegistry,
        _ operations: FileOperations,
        _ conditions: Conditions
    ) {
        let (hasOperands, canMove) = (conditions.hasOperands, conditions.canMove)
        commands.register(Command(.copy, "Copy…", [.f(5)], barLabel: "Copy"), enabled: hasOperands) { argument in
            operations.transfer(.copy, sameFolder: false, dialog: .quick, switches: argument.text)
        }
        commands.register(Command(.copyOtherPanel, "Copy to Other Panel…"), enabled: hasOperands) { argument in
            operations.transfer(.copy, sameFolder: false, dialog: .quick, switches: argument.text)
        }
        commands.register(Command(.copyWithOptions, "Copy with Options…"), enabled: hasOperands) {
            operations.transfer(.copy, sameFolder: false, dialog: .options, switches: nil)
        }
        commands.register(Command(.copyNoAsk, "Copy to Other Panel Now"), enabled: hasOperands) {
            operations.transfer(.copy, sameFolder: false, dialog: .immediate, switches: nil)
        }
        commands.register(Command(.copySamePanel, "Copy in Same Folder…", [.f(5, .shift)]), enabled: canMove) {
            operations.transfer(.copy, sameFolder: true, dialog: .quick, switches: nil)
        }
        commands.register(
            Command(.renameMove, "Rename/Move…", [.f(6)], barLabel: "Move"),
            enabled: canMove
        ) { argument in
            operations.transfer(.move, sameFolder: false, dialog: .quick, switches: argument.text)
        }
        commands.register(Command(.moveOnly, "Move to Other Panel…"), enabled: canMove) { argument in
            operations.transfer(.move, sameFolder: false, dialog: .quick, switches: argument.text)
        }
        commands.register(Command(.moveWithOptions, "Rename/Move with Options…"), enabled: canMove) {
            operations.transfer(.move, sameFolder: false, dialog: .options, switches: nil)
        }
        commands.register(Command(.moveNoAsk, "Move to Other Panel Now"), enabled: canMove) {
            operations.transfer(.move, sameFolder: false, dialog: .immediate, switches: nil)
        }
    }

    /// Shift+F6 and the rename of the item under the cursor.
    private static func registerRenames(
        in commands: CommandRegistry,
        _ operations: FileOperations,
        _ conditions: Conditions
    ) {
        let source = conditions.source
        // Some handlers run other commands; the registry keeps them, so they hold it unowned.
        unowned let registry = commands
        commands.register(
            Command(.renameOnly, "Rename", [.f(6, .shift)]),
            enabled: conditions.canRename
        ) { argument in
            if let newName = argument.text {
                operations.renameCursorItem(to: newName)
            } else if source().selectionCount > 1 {
                // Several items are renamed with a mask (07 › Shift+F6 with several items).
                operations.renameSelection()
            } else {
                // The shell owns the editor that sits on the row; it calls back with the new name.
                registry.perform(.editNameInPlace)
            }
        }
        commands.register(
            Command(.renameSingleFile, "Rename File Under Cursor"),
            enabled: conditions.canRename
        ) { argument in
            if let newName = argument.text {
                operations.renameCursorItem(to: newName)
            } else {
                registry.perform(.editNameInPlace)
            }
        }
    }

    /// New folder (F7, Shift+F7) and new text file (Shift+F4).
    private static func registerNewItems(in owner: Kernel, _ operations: FileOperations, _ conditions: Conditions) {
        // The handlers stay with the kernel's registry; they must not keep the kernel in turn.
        unowned let kernel = owner
        let (source, takesNew) = (conditions.source, conditions.takesNew)
        // `.text`: the names, as typed into the dialog or as `N="…" G`; the folders are then made without asking.
        kernel.commands.register(
            Command(.makeDirectory, "New Folder…", [.f(7)], barLabel: "NewFolder"),
            enabled: { takesNew(source()) },
            parameterized: { argument in
                operations.makeDirectory(in: kernel.panels.source, names: argument.text)
            }
        )
        kernel.commands.register(
            Command(.makeDirectoryOther, "New Folder in Other Panel…", [.f(7, .shift)]),
            enabled: { takesNew(kernel.panels.target.model) },
            parameterized: { argument in
                operations.makeDirectory(in: kernel.panels.target, names: argument.text)
            }
        )
        // `.text("1")` or `.index(1)`: create the file but do not open the editor (10 › New text file).
        kernel.commands.register(
            Command(.newTextFile, "New Text File…", [.f(4, .shift)]),
            enabled: { takesNew(source()) },
            parameterized: { argument in
                operations.newTextFile(opensEditor: argument.text != "1" && argument.index != 1)
            }
        )
    }

    /// F8 to the Trash, Shift+F8 for good.
    private static func registerDeletes(
        in commands: CommandRegistry,
        _ operations: FileOperations,
        _ conditions: Conditions
    ) {
        commands.register(
            Command(
                .delete,
                "Move to Trash",
                [.f(8), Shortcut(.backspace, .command), Shortcut(.forwardDelete)],
                barLabel: "Delete"
            ),
            enabled: conditions.canMove
        ) { operations.delete(shifted: false) }
        commands.register(
            Command(
                .deleteDirectly,
                "Delete Permanently…",
                [.f(8, .shift), Shortcut(.backspace, [.command, .option]), Shortcut(.forwardDelete, .shift)]
            ),
            enabled: conditions.canMove
        ) { operations.delete(shifted: true) }
    }

    /// The menus, the context menu and the toolbar buttons of the commands.
    private static func addMenusAndToolbar(to kernel: Kernel) {
        kernel.menus.add([.copy, .copySamePanel, .renameMove, .renameOnly], to: .filesTransfer)
        kernel.menus.add(
            [.copyWithOptions, .moveWithOptions, .copyNoAsk, .moveNoAsk],
            to: MenuSection(.files, order: 25)
        )
        kernel.menus.add([.makeDirectory, .makeDirectoryOther, .newTextFile], to: .filesCreate)
        kernel.menus.add([.delete, .deleteDirectly], to: .filesDelete)
        kernel.menus.addToContextMenu([.copy, .renameMove, .renameOnly, .delete], in: .transfer, onItemOnly: true)
        kernel.menus.addToContextMenu([.makeDirectory, .newTextFile], in: .create)

        kernel.toolbar.add(
            .copy,
            symbol: "doc.on.doc",
            group: 20,
            hint: "Copy the selected files to the folder of the other panel."
        )
        kernel.toolbar.add(
            .renameMove,
            symbol: "arrow.right.doc.on.clipboard",
            group: 20,
            hint: "Move the selected files to the other panel's folder, or rename them."
        )
        kernel.toolbar.add(
            .makeDirectory,
            symbol: "folder.badge.plus",
            group: 20,
            hint: "Create a new folder in the current folder."
        )
        kernel.toolbar.add(
            .delete,
            symbol: "trash",
            group: 20,
            hint: "Move the selected files and folders to the Trash."
        )
        kernel.toolbar.setSymbol("doc.badge.gearshape", for: .copyWithOptions)
        kernel.toolbar.setSymbol("doc.badge.plus", for: .newTextFile)
        kernel.toolbar.setSymbol("trash.slash", for: .deleteDirectly)
    }

    /// The operation log is written in bursts; this is where the last one goes out.
    ///
    /// The program is quitting and this is the main thread: a log on a volume that has stopped
    /// answering is waited for a moment and no longer.
    public func stop() {
        operations?.flushLog()
    }

    /// The log's last lines are written while the program is still there to wait for them:
    /// in the background, so that a log on a volume that has stopped answering holds up
    /// nothing but itself, and no longer than the user wants to wait (`cancellation`).
    /// `stop()` then finds nothing left to write.
    @preconcurrency
    public func prepareToQuit(cancellation: CancellationFlag, completion: @escaping @Sendable () -> Void) {
        guard let operations else {
            completion()
            return
        }
        operations.flushLog(cancellation: cancellation, completion: completion)
    }

    /// Registers the commands, their menus and buttons, the configuration pages and the transfer service.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let fileOperations = FileOperations(kernel, clipboard: clipboard)
        operations = fileOperations
        kernel.fileSystems.addVolumeCloser { [weak fileOperations] volume, _ in fileOperations?.closeLog(on: volume) }
        let conditions = Conditions(kernel)
        Self.registerTransfers(in: kernel.commands, fileOperations, conditions)
        Self.registerRenames(in: kernel.commands, fileOperations, conditions)
        Self.registerNewItems(in: kernel, fileOperations, conditions)
        Self.registerDeletes(in: kernel.commands, fileOperations, conditions)
        Self.addMenusAndToolbar(to: kernel)
        kernel.preferences.add(OperationSettings.copyDeletePage)
        kernel.preferences.add(OperationSettings.logPage)
        kernel.services.register((any FileTransferService).self, fileOperations)
    }

    deinit {
        // Nothing to release: the log wrote its last lines when the program stopped.
    }
}
