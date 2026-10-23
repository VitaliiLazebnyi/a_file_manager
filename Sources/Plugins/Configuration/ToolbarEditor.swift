import AFMKernel

/// The button bar while it is being edited (spec 14 › Button bars, The Change button bar
/// dialog): a list of commands and separators.
///
/// Nothing changes outside until `commit`. Main thread only.
///
/// The bar holds commands of the program only; a program with parameters goes on the bar as a
/// user command, which is what Total Commander's `em_` commands are for.
@MainActor
internal final class ToolbarEditor {
    private let toolbar: ToolbarRegistry
    private let settings: any SettingsStore
    private let store: ConfigurationStore
    /// The bar in order; nil is a separator.
    internal private(set) var items: [CommandID?] = []
    /// The pictures the user chose, by command name.
    internal private(set) var symbols: [String: String] = [:]
    /// The bar is the plugins' proposal, not a layout of the user's own.
    internal private(set) var isDefault = true
    /// Whether anything was edited since the editor opened or last committed.
    internal private(set) var isChanged = false

    /// An editor over the bar of `toolbar` as `settings` hold it, with the pictures of `store`.
    internal init(toolbar: ToolbarRegistry, settings: any SettingsStore, store: ConfigurationStore) {
        self.toolbar = toolbar
        self.settings = settings
        self.store = store
        discard()
    }

    /// Back to the bar and the pictures as they are stored.
    internal func discard() {
        items = toolbar.layout(from: settings).map { $0?.command }
        isDefault = settings.data(forKey: ToolbarRegistry.settingsKey) == nil
        symbols = store.symbols
        isChanged = false
    }

    private func edited() {
        isDefault = false
        isChanged = true
    }

    /// Inserts directly after `row` (at the end without one) and returns the new row.
    @discardableResult
    internal func insert(_ command: CommandID?, after row: Int?) -> Int {
        let index = row.map { min($0 + 1, items.count) } ?? items.count
        items.insert(command, at: max(0, index))
        edited()
        return index
    }

    /// Takes the command or separator at `row` off the bar; a row that is not there is ignored.
    internal func remove(at row: Int) {
        guard items.indices.contains(row) else {
            return
        }
        items.remove(at: row)
        edited()
    }

    /// Moves a row up (-1) or down (+1); returns where it is afterwards.
    @discardableResult
    internal func move(_ row: Int, by offset: Int) -> Int {
        let target = row + offset
        guard items.indices.contains(row), items.indices.contains(target) else {
            return row
        }
        items.swapAt(row, target)
        edited()
        return target
    }

    /// The bar the plugins propose, in place of the user's own layout.
    internal func resetToDefault() {
        items = toolbar.defaultLayout.map { $0?.command }
        isDefault = true
        isChanged = true
    }

    /// The symbol shown for a command: the user's, else the one its plugin gave it.
    internal func symbol(for command: CommandID) -> String {
        symbols[command.rawValue] ?? toolbar.symbol(for: command) ?? "square.dashed"
    }

    /// An empty name takes the user's picture away again.
    internal func setSymbol(_ symbol: String, for command: CommandID) {
        symbols[command.rawValue] = symbol.isEmpty ? nil : symbol
        isChanged = true
    }

    /// OK: stores the pictures and the layout (or forgets the layout, for the default bar) and
    /// has the bar drawn again; does nothing when nothing was edited.
    internal func commit() {
        guard isChanged else {
            return
        }
        store.symbols = symbols
        for (name, symbol) in symbols { toolbar.setSymbol(symbol, for: CommandID(rawValue: name)) }
        // Storing the layout also has the bar drawn again, with the new pictures.
        if isDefault {
            toolbar.resetLayout(in: settings)
        } else {
            toolbar.setLayout(items, in: settings)
        }
        isChanged = false
    }

    deinit {
        // Nothing to release.
    }
}
