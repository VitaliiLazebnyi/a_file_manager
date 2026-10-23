/// What carries over from the name mask to the extension mask: the folder-dot switch and the
/// time source apply "from this position on" (spec 18 › Name and path parts, Date and time).
internal struct MaskState {
    /// `[I]` is on: a folder's name has no extension.
    internal var foldersHaveNoExtension = false
    /// The time source of the date placeholders, `[T1]` to `[T4]`.
    internal var timeSource = 1
    /// What the time source is moved by (`[T1+5h]`), if anything.
    internal var timeOffset: RenameMask.TimeOffset?
}
