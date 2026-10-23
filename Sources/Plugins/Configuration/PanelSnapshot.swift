/// What one panel contributes to the parameters of a command.
internal struct PanelSnapshot: Equatable {
    /// The panel's directory as the user writes it, with a trailing `/`.
    internal var path: String
    /// The name under the cursor; nil on `[..]` and in an empty list.
    internal var cursorName: String?
    /// The marked names, in list order.
    internal var selection: [String] = []
}
