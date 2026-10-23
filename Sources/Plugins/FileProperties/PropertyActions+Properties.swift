import AFMContracts
import AFMKernel
import Foundation

/// Properties (spec 07 › Properties).
extension PropertyActions {
    /// What the Properties dialog shows, put together on the job's thread.
    private struct PropertiesReport {
        /// The dialog's title: the item's name, or how many items there are.
        let name: String
        /// The lines; none when the item could not be read.
        let rows: [PropertyRow]
        /// The items described, for the Finder Info button.
        let urls: [URL]
    }

    /// The item under the cursor, the selection when it holds several items, or on `[..]` the
    /// folder the panel shows.
    internal func showProperties() {
        let model = source.model
        let directory = model.directory
        // (The list of a long selection is made on the job's thread.)
        let operands = model.operandsSnapshot()
        let cursorItem = model.cursorItem
        let (registry, store) = (fileSystems, comments)
        let title = "Properties:"
        kernel.jobs.run(
            title: title,
            work: { monitor -> PropertiesReport in
                let sheet = PropertySheet(
                    fileSystems: registry,
                    comments: store,
                    cancellation: monitor.cancellation,
                    meter: ProgressMeter(monitor, title: title, total: 0)
                )
                let selected = operands.markedCount > 1 ? operands.markedItems() : []
                if !selected.isEmpty {
                    return PropertiesReport(
                        name: "\(selected.count) items",
                        rows: sheet.rows(forSeveral: selected),
                        urls: selected.map(\.url)
                    )
                }
                guard
                    let item = cursorItem
                        ?? (try? registry.provider(for: directory))?
                        .item(
                            at: directory,
                            cancellation: monitor.cancellation
                        )
                else {
                    return PropertiesReport(name: directory.lastPathComponent, rows: [], urls: [])
                }
                return PropertiesReport(
                    name: item.name.isEmpty ? registry.displayPath(item.url) : item.name,
                    rows: sheet.rows(for: item),
                    urls: [item.url]
                )
            },
            completion: { [self] report in show(report) }
        )
    }

    /// Shows the dialog, with a Finder Info button when every item is local; main thread.
    private func show(_ report: PropertiesReport) {
        guard !report.rows.isEmpty else {
            interaction.inform(
                "The properties of \(PropertyText.shown(report.name)) cannot be read!",
                detail: "",
                style: .warning
            )
            return
        }
        let canShowFinderInfo = report.urls.allSatisfy(\.isFileURL)
        let answer = interaction.form(
            "Properties: \(report.name)",
            detail: "",
            fields: report.rows.map { .note("\($0.label): \($0.value)") },
            buttons: ["OK"] + (canShowFinderInfo ? ["Finder Info"] : [])
        )
        if answer?.button == 1 { showFinderInfo(report.urls) }
    }
}
