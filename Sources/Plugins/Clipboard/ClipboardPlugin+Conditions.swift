import AFMKernel
import Foundation

/// When the plugin's commands are offered.
extension ClipboardPlugin {
    /// When the commands are offered, asked of the source panel whenever a menu is drawn.
    @MainActor
    internal struct Conditions {
        /// The model of the source panel.
        internal let model: () -> PanelModel
        /// Whether the source panel has something to work on.
        internal let hasOperands: () -> Bool
        /// Whether the operands are on a local disk, the only ones the system clipboard carries.
        internal let hasLocalOperands: () -> Bool
        /// Whether something new can be put into the folder the panel shows: where entries
        /// can only be removed (a list of files from anywhere, `.removeOnly`) nothing can.
        internal let isWritable: () -> Bool
        /// Whether the folder the panel shows is a list whose entries can only be removed.
        internal let isRemoveOnly: () -> Bool

        /// The conditions for the panels of `owner`, which they hold unowned.
        internal init(_ owner: Kernel) {
            unowned let kernel = owner
            let sourceModel = { kernel.panels.source.model }
            let capabilities = { kernel.fileSystems.capabilities(for: sourceModel().directory) }
            model = sourceModel
            hasOperands = { sourceModel().hasOperands }
            hasLocalOperands = { sourceModel().hasOperands && sourceModel().directory.isFileURL }
            isWritable = { capabilities().contains(.write) && !capabilities().contains(.removeOnly) }
            isRemoveOnly = { capabilities().contains(.removeOnly) }
        }
    }
}
