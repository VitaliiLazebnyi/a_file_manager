/// What a button, a Start-menu item or a user command does: the three fields the editors of
/// Total Commander share (spec 14 › The command language).
internal struct CommandAction: Codable, Equatable {
    /// A command of the program (`cm_…`, `em_…`), several of them separated by commas,
    /// `cd <path>`, or a program or shell line.
    internal var command = ""
    /// Parameters with placeholders (spec 18 › Button and command parameters).
    internal var parameters = ""
    /// The folder a program starts in; with `cd`, the folder the other panel shows.
    internal var startPath = ""
}
