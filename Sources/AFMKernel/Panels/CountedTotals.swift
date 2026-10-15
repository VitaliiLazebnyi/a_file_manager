/// The two halves of a panel's totals, kept once they are counted: those of the list until it
/// changes, those of the selection until it does.
internal struct CountedTotals {
    /// The figures of the shown entries; nil until counted.
    internal var list: PanelModel.Totals?
    /// Whether the shown entries' sizes add up the same in any order (`Tally.isPlain`), so that
    /// a part can be taken off the sum again.
    internal var listIsPlain = false
    /// The figures of the marked entries; nil until counted.
    internal var selected: PanelModel.Totals?

    /// Takes the figures of the list from a count of it; nil leaves them to be counted.
    internal mutating func setList(_ tally: Tally?) {
        list = tally.map { PanelModel.Totals(total: PanelModel.Counts($0)) }
        listIsPlain = tally?.isPlain ?? false
    }

    /// Forgets both halves: they are counted again when asked for.
    internal mutating func forget() {
        setList(nil)
        selected = nil
    }
}
