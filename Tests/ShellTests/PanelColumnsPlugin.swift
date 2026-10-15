import AFMKernel
import Foundation

/// Offers two columns, as a content plugin would: "Upper", which is slow and counted by a
/// probe, and "Length", aligned to the right.
@MainActor
internal final class PanelColumnsPlugin: Plugin {
    /// The plugin's name.
    internal let name = "Columns"
    /// Counts the calls of the slow column.
    internal let probe: PanelProbe

    /// A plugin whose slow column `probe` counts.
    internal init(probe: PanelProbe) {
        self.probe = probe
    }

    /// Registers the two columns.
    internal func start(in kernel: Kernel) {
        kernel.columns.register(
            ContentColumn(id: "upper", title: "Upper", width: 90) { [probe] item in
                probe.enter(item.name)
                Thread.sleep(forTimeInterval: 0.01)
                probe.leave()
                return item.name.uppercased()
            }
        )
        kernel.columns.register(ContentColumn(id: "length", title: "Length", alignsRight: true) { "\($0.name.count)" })
    }

    deinit {
        // Nothing to release.
    }
}
