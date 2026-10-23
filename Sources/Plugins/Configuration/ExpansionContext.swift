import Foundation

/// Everything the placeholders of a Parameters field can refer to
/// (spec 18 › Button and command parameters).
internal struct ExpansionContext {
    /// The left panel.
    internal var left: PanelSnapshot
    /// The right panel.
    internal var right: PanelSnapshot
    /// The right panel is the active one.
    internal var sourceIsRight = false
    /// The variables `%|NAME|` refers to.
    internal var environment: [String: String] = [:]
    /// The words typed after the name of a user command; the `%A` codes refer to them.
    internal var arguments = ""
    /// Where a list file (`%L`, `%F` …) is to be written.
    internal var listFolder = FileManager.default.temporaryDirectory
    /// The name of the list file without extension; unique per run.
    internal var listName = UUID().uuidString
    /// The same words when they came out of an expansion already: their values stay values.
    ///
    /// Empty stands for `arguments` as the user typed them.
    internal var argumentPieces: [ExpandedPiece] = []

    /// The active panel (the left one unless `sourceIsRight`).
    internal var source: PanelSnapshot { sourceIsRight ? right : left }
    /// The other panel.
    internal var target: PanelSnapshot { sourceIsRight ? left : right }
}
