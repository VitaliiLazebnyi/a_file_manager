import AFMKernel

/// One entry of the Lister's menus: what it is called, its keys, whether it applies right now
/// and what it does.
///
/// The menus and the keyboard are both driven by the same list, so a key does exactly what its menu
/// entry does (spec 10 › Menu bar, 10 › General keys).
internal struct ViewerAction {
    /// The entry's text in the menu.
    internal let title: String
    /// The keys that run it; the menu shows the first.
    internal var shortcuts: [Shortcut] = []
    /// Whether it can run now; a disabled entry is greyed and its keys do nothing.
    internal var isEnabled = true
    /// Whether the menu shows a check mark at it.
    internal var isChecked = false
    /// What it does, on the main thread.
    internal let run: () -> Void
}
