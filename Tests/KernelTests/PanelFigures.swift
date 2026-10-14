import AFMKernel

/// What a panel model shows, worked out the plain way, to check the model's own figures by.
@MainActor
internal enum PanelFigures {
    /// The totals as they are defined, counted from scratch from the rows the model shows and
    /// the marks on them.
    internal static func counted(_ model: PanelModel) -> PanelModel.Totals {
        var totals = PanelModel.Totals()
        let firstRow = model.hasParentRow ? 1 : 0
        for (index, item) in model.items.enumerated() {
            let size = item.isFolder ? (item.computedSize ?? 0) : item.size
            totals.totalBytes += size
            if item.isFolder {
                totals.totalFolders += 1
            } else {
                totals.totalFiles += 1
            }
            guard model.isSelected(row: index + firstRow) else {
                continue
            }
            totals.selectedBytes += size
            if item.isFolder {
                totals.selectedFolders += 1
            } else {
                totals.selectedFiles += 1
            }
        }
        return totals
    }

    /// Everything a panel shows, as text, to compare two models by: entries shown and listed,
    /// marks, cursor, totals, filter, order and the calculated sizes in both lists.
    internal static func state(_ model: PanelModel) -> [String] {
        [
            model.items.map(\.name).joined(separator: "|"),
            model.listedItems.map(\.name).joined(separator: "|"),
            model.selectedNames.joined(separator: "|"),
            "\(model.cursor)",
            model.cursorItem?.name ?? "-",
            "\(model.totals)",
            model.filter?.title ?? "-",
            "\(model.sort)",
            model.items.map { "\($0.computedSize ?? -1)" }.joined(separator: ","),
            model.listedItems.map { "\($0.computedSize ?? -1)" }.joined(separator: ",")
        ]
    }
}
