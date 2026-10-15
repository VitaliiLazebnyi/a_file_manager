import AFMKernel
import Foundation

/// Folder sizes that came in during one turn of the main loop for a tab, with the folder they
/// were measured in and the calculation they belong to; the tab takes them together.
internal struct PanelSizeArrivals {
    /// The folder the sized entries are in.
    internal let directory: URL
    /// The calculation; when it is cancelled, the sizes are of no use.
    internal let flag: CancellationFlag
    /// The sizes, by entry name.
    internal var sizes: [(name: String, size: Int64)]
}
