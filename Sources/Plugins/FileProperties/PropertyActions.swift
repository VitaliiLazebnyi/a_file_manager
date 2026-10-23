import AFMKernel
import Foundation

/// The behaviour behind the commands.
///
/// **Threading.** Commands start on the main thread and only prepare there: they read the
/// panel's state and ask the user. Whatever touches a file system, even to pre-fill a dialog,
/// runs inside a job on the job's thread; the completion returns to the main thread to show
/// the result and refresh the panels.
@MainActor
internal final class PropertyActions {
    /// The kernel whose panels, jobs and dialogs the commands use.
    ///
    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// Where comments are read and written.
    internal let comments: CommentStore
    /// Opens Finder's Info window of these items.
    internal let showFinderInfo: ([URL]) -> Void

    /// The panel the commands work on.
    internal var source: any PanelHandle { kernel.panels.source }
    /// Where the commands ask and tell the user.
    internal var interaction: any UserInteraction { kernel.interaction }
    /// The file systems of every location.
    internal var fileSystems: FileSystemRegistry { kernel.fileSystems }

    /// The actions of `kernel`, keeping comments in `comments`; `showFinderInfo` opens Finder's Info windows.
    internal init(_ kernel: Kernel, comments: CommentStore, showFinderInfo: @escaping ([URL]) -> Void) {
        self.kernel = kernel
        self.comments = comments
        self.showFinderInfo = showFinderInfo
    }

    /// The first failures of an operation as the text of a message: a message is laid out
    /// whole, and one line per item of a large selection would be megabytes of it.
    ///
    /// `total` is how many failed, of which `failures` are the first; at most 20 are shown.
    internal static func summary(of failures: [String], total: Int) -> String {
        let shown = failures.prefix(20)
        return shown.joined(separator: "\n") + (total > shown.count ? "\n… and \(total - shown.count) more" : "")
    }

    /// Shows calculated folder sizes in a panel.
    ///
    /// They were written into a copy of the list on the job's thread (`prepared`), which the model
    /// takes in one step; if its list is no longer the one the copy was made of, the sizes are set
    /// by name instead. Main thread.
    internal static func show(
        _ sizes: [(name: String, size: Int64)],
        prepared: PanelModel.Prepared?,
        in model: PanelModel
    ) {
        guard !sizes.isEmpty else {
            return
        }
        if let prepared, model.apply(prepared) != .stale {
            return
        }
        model.setComputedSizes(sizes)
    }

    /// Opens Finder's Info window of the operands, or of the folder the panel shows when there are none.
    ///
    /// Finder opens one window per item: more than `finderInfoRequestLimit` is never meant, and the
    /// list of a long selection is not made for it.
    internal func showFinderInfoOfOperands() {
        let model = source.model
        let operands = model.operandsSnapshot()
        let limit = FilePropertiesPlugin.finderInfoRequestLimit
        var urls: [URL] = []
        if operands.markedCount > limit {
            for index in operands.shownItems.indices where operands.isMarked(at: index) {
                urls.append(operands.shownItems[index].url)
                if urls.count == limit { break }
            }
        } else {
            urls = operands.items().map(\.url)
        }
        showFinderInfo(urls.isEmpty ? [model.directory] : urls)
    }

    deinit {
        // Nothing to release.
    }
}
