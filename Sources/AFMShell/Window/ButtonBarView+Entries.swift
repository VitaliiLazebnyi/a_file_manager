import AFMKernel

/// What the bar shows of a layout, and the tool tips of its buttons.
extension ButtonBarView {
    /// The layout without what cannot be shown.
    ///
    /// Buttons whose command no plugin registered are left out, and so are the separators and
    /// line breaks that would then stand at an end, side by side, or around an empty line.
    internal static func entries(
        of layout: [ToolbarRegistry.Button?],
        commands: CommandRegistry
    ) -> [ToolbarRegistry.Button?] {
        let shown = layout.filter { button in
            button.map { $0.command == ToolbarRegistry.lineBreak || commands[$0.command] != nil } ?? true
        }
        var remaining = shown.compactMap(\.self).filter { $0.command != ToolbarRegistry.lineBreak }.makeIterator()
        return ButtonBarArrangement(entries: shown.map { $0?.command }).entries
            .map { id in
                guard let id else {
                    return nil
                }
                return id == ToolbarRegistry.lineBreak
                    ? ToolbarRegistry.Button(command: id, symbol: "") : remaining.next()
            }
    }

    /// The tooltip of a button: the command's title and its main key, `Find Files… (⌥F7)`, and
    /// below them what the button does, when its plugin says (`hint`).
    internal static func toolTip(for command: Command, keys: KeyBindings, hint: String?) -> String {
        let title =
            keys.shortcuts(for: command.id).first.map { "\(command.title) (\($0.displayText))" } ?? command.title
        return hint.map { "\(title)\n\($0)" } ?? title
    }
}
