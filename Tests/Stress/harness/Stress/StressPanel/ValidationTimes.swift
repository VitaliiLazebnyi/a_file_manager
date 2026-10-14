/// How long one round of validation took, in seconds, by part.
internal struct ValidationTimes {
    /// The bars of the main window.
    internal var bars: Double
    /// The enabled and checked closures of every command.
    internal var commands: Double
    /// Every item of the main menu and its submenus.
    internal var menu: Double
}
