public import AFMKernel
import Foundation

/// The sections of the file list's context menu, shared by every plugin that adds entries.
extension ContextMenuSection {
    /// Opening the item: open, open with, view.
    public static let open = ContextMenuSection(order: 10)
    /// Copying, moving and renaming.
    public static let transfer = ContextMenuSection(order: 20)
    /// Cut, copy and paste.
    public static let clipboard = ContextMenuSection(order: 30)
    /// Making a folder or a file.
    public static let create = ContextMenuSection(order: 40)
    /// Tools that work on the item.
    public static let tools = ContextMenuSection(order: 50)
    /// Packing and unpacking.
    public static let archives = ContextMenuSection(order: 45)
    /// Properties, attributes and comments.
    public static let properties = ContextMenuSection(order: 60)
}
