/// The layouts of a file list (spec 03 › View types).
public enum PanelViewMode: Int, Codable, Sendable {
    /// Names only, in several columns side by side.
    case brief = 1
    /// One row per item with all columns.
    case full = 0
    /// A grid of pictures of the files.
    case thumbnails = 2
}
