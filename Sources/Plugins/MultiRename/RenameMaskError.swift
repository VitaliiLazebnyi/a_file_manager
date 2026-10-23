/// Why a mask gives no name for an item; the preview then shows `<Error!>` (spec 09 › Rename pipeline).
internal enum RenameMaskError: Error, Equatable {
    /// `[=plugin.field]`: content plugins do not exist here.
    case contentPluginsUnavailable
    /// `[X]` and the clipboard holds no text.
    case emptyClipboard
    /// A placeholder that cannot be read, as written.
    case invalidPlaceholder(String)
    /// `[T4]` and the item is no picture with a recorded date.
    case noContentDate
    /// A counter that runs beyond what a number can hold.
    case numberTooLarge
}
