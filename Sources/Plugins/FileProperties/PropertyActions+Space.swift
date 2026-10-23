import AFMKernel
import Foundation

/// Calculate Occupied Space and Calculate All Folder Sizes (spec 07 › Calculate occupied space).
extension PropertyActions {
    /// What Calculate Occupied Space measures: noted on the main thread at no cost, and looked
    /// through on the job's thread.
    private struct SpaceRequest {
        /// The operands of the source panel.
        let operands: PanelModel.Operands
        /// The folder the source panel shows.
        let directory: URL
        /// The list the panel shows, to write the folder sizes into a copy of it.
        let basis: PanelModel.Basis
        /// The folder of the other panel, whose volume decides what a copy would need.
        let targetDirectory: URL

        /// Measures the operands; blocks, on the job's thread.
        func measure(fileSystems: FileSystemRegistry, monitor: any JobMonitor, title: String) -> SpaceResult {
            var result = SpaceResult()
            let items = operands.items()
            result.targetCluster = LocalInfo.clusterSize(at: targetDirectory)
            let calculator = SpaceCalculator(
                fileSystems: fileSystems,
                cancellation: monitor.cancellation,
                targetCluster: result.targetCluster,
                meter: ProgressMeter(monitor, title: title, total: 0)
            )
            let perItem = calculator.measure(items)
            result.totals = perItem.reduce(SpaceTotals(), +)
            for (item, measured) in zip(items, perItem) where item.isFolder && item.isRealDirectory {
                result.sizes.append((item.name, measured.bytes))
            }
            result.isLocal = items.allSatisfy(\.url.isFileURL)
            if !monitor.cancellation.isCancelled, !result.sizes.isEmpty {
                result.prepared = PanelModel.prepare(basis, computedSizes: result.sizes)
            }
            result.volume = (try? fileSystems.provider(for: directory))?
                .volume(
                    of: directory,
                    cancellation: monitor.cancellation
                )
            result.cancelled = monitor.cancellation.isCancelled
            return result
        }
    }

    /// What Calculate Occupied Space found.
    private struct SpaceResult {
        /// The sums of all operands.
        var totals = SpaceTotals()
        /// The folders that were measured, with their sizes, and their names.
        var sizes: [(name: String, size: Int64)] = []
        /// The sizes written into a copy of the list, for the model to take in one step.
        var prepared: PanelModel.Prepared?
        /// Whether every operand is on the Mac's own file system, which knows the space taken on disk.
        var isLocal = true
        /// The allocation unit of the target volume; nil where it is not known.
        var targetCluster: Int64?
        /// The volume of the source folder, for its free space.
        var volume: VolumeInfo?
        /// Whether the user stopped the calculation.
        var cancelled = false
    }

    /// Measures the operands with everything inside them and shows the sums; measured folders
    /// show their sizes in the panel and, if the setting says so, are selected.
    internal func calculateOccupiedSpace() {
        let model = source.model
        // The list of the operands is made on the job's thread, and so is everything that
        // grows with it: the sum, which folders were measured, whether all of it is local.
        // Offered only where there are operands.
        let request = SpaceRequest(
            operands: model.operandsSnapshot(),
            directory: model.directory,
            basis: model.basis,
            targetDirectory: kernel.panels.target.model.directory
        )
        let registry = fileSystems
        let title = "Calculating occupied space:"
        kernel.jobs.run(
            title: title,
            work: { monitor in request.measure(fileSystems: registry, monitor: monitor, title: title) },
            completion: { [self] result in
                if !result.cancelled, model.directory.isSameLocation(as: request.directory) {
                    // A measured folder shows its size in the Size column and is drawn as selected.
                    // One change for all of them: each is a search of the list and a redraw.
                    let selects = kernel.settings.flag(FilePropertiesPlugin.Settings.selectMeasured, default: true)
                    Self.show(result.sizes, prepared: result.prepared, in: model)
                    if selects { model.setSelected(true, names: result.sizes.map(\.name)) }
                }
                interaction.inform(
                    "Total space occupied:",
                    detail: SpaceReport.text(
                        result.totals,
                        sourceIsLocal: result.isLocal,
                        targetCluster: result.targetCluster,
                        volume: result.volume,
                        cancelled: result.cancelled
                    ),
                    style: .information
                )
            }
        )
    }

    /// The size of every folder of the source panel, shown in the Size column
    /// (spec 03 › Counting rules, `cm_CountDirContent`).
    internal func countDirectoryContents() {
        let model = source.model
        let directory = model.directory
        // The list is looked through on the job's thread: it may be a million entries long.
        let (shown, basis) = (model.items, model.basis)
        let registry = fileSystems
        let title = "Calculating folder sizes:"
        kernel.jobs.run(
            title: title,
            work: { monitor -> (sizes: [(name: String, size: Int64)], prepared: PanelModel.Prepared?) in
                let folders = shown.filter { $0.isFolder && $0.isRealDirectory }
                let measured = SpaceCalculator(
                    fileSystems: registry,
                    cancellation: monitor.cancellation,
                    meter: ProgressMeter(monitor, title: title, total: 0),
                    measuresAllocated: false
                )
                .measure(folders)
                let sizes = zip(folders, measured).map { folder, totals in (name: folder.name, size: totals.bytes) }
                return (sizes, sizes.isEmpty ? nil : PanelModel.prepare(basis, computedSizes: sizes))
            },
            completion: { result in
                guard model.directory.isSameLocation(as: directory) else {
                    return
                }
                Self.show(result.sizes, prepared: result.prepared, in: model)
            }
        )
    }
}
