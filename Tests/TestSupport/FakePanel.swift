public import AFMKernel
public import Foundation

/// A panel without a window.
///
/// It reads directories at once, on the calling thread, so a test can look at the result right after a command. Main
/// thread only, like a real panel.
public final class FakePanel: PanelHandle {
    /// The panel's tabs; a tab that becomes the active one is read when it was never shown.
    public let tabs: PanelTabs
    /// Always false: a directory is read inside the call that asks for it.
    public let isLoading = false
    /// The layout the plugins chose; it changes nothing here.
    public var viewMode = PanelViewMode.full
    /// The plugin columns the plugins chose; they change nothing here.
    public var extraColumns: [String] = []
    /// The messages of the readings that failed, in order: what a real panel would tell the user.
    public private(set) var failures: [String] = []
    /// The pair this panel belongs to, which `focus()` makes it the source of.
    internal weak var owner: FakePanelSet?
    private let fileSystems: FileSystemRegistry

    /// The names of the entries the active tab shows, in order.
    public var names: [String] { model.items.map(\.name) }

    /// A panel showing `directory`, read at once through `fileSystems`.
    public init(showing directory: URL, fileSystems: FileSystemRegistry) {
        self.fileSystems = fileSystems
        tabs = PanelTabs(PanelModel(directory: directory))
        tabs.onChange = { [weak self] in
            // A tab that was never shown is read when it becomes the active one.
            guard let self, !model.isListed else {
                return
            }
            show(model.directory, focus: nil, history: .keep, completion: nil)
        }
        show(directory, focus: nil, history: .keep, completion: nil)
    }

    /// Reads `location` at once and shows it; a failure is recorded in `failures` and leaves the panel where it was.
    ///
    /// `completion` is called before this returns.
    @preconcurrency
    public func show(
        _ location: URL,
        focus: String?,
        history: PanelModel.HistoryEffect,
        completion: (@MainActor (Bool) -> Void)?
    ) {
        do {
            let result = try PanelLoader.load(location, showHidden: model.showHidden, fileSystems: fileSystems)
            model.show(result.listing, focus: focus ?? result.focus, history: history)
            completion?(true)
        } catch {
            failures.append(error.localizedDescription)
            completion?(false)
        }
    }

    /// Reads the active tab's directory again at once (or the nearest folder above that is
    /// there); `completion` is called before this returns.
    @preconcurrency
    public func reload(focus: String?, quietly _: Bool, completion: (@MainActor () -> Void)?) {
        if let result = try? PanelLoader.load(
            model.directory,
            showHidden: model.showHidden,
            fileSystems: fileSystems,
            climbing: true
        ) {
            model.update(with: result.listing, focus: focus)
        }
        completion?()
    }

    /// Makes this panel the source of its pair.
    public func focus() {
        owner?.source = self
    }

    /// Puts the cursor on the entry called `name`, when there is one.
    public func moveCursor(toName name: String) {
        if let row = model.row(ofName: name) {
            model.moveCursor(to: row)
        }
    }

    deinit {
        // Nothing to release.
    }
}
