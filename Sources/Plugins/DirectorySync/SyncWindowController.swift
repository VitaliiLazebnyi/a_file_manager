import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// The "Synchronize directories" window (spec 09 › Window and workflow).
///
/// It draws a `SyncSession` and forwards clicks and keys to it; nothing here touches a file system.
/// Main thread only.
internal final class SyncWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate,
    NSMenuDelegate
{
    /// A column of the result list.
    internal struct Column {
        /// Its identifier, which also names the side and the value it shows.
        internal let id: String
        /// Its header.
        internal let title: String
        /// Its width at the start.
        internal let width: CGFloat
    }

    /// The time tolerances of the pop-up, in seconds.
    internal static let tolerances = [0, 2, 3]
    /// The columns of the result list, left to right.
    internal static let columns = [
        Column(id: "leftName", title: "Name", width: 210), Column(id: "leftSize", title: "Size", width: 90),
        Column(id: "leftDate", title: "Date", width: 140), Column(id: "action", title: "<=>", width: 44),
        Column(id: "rightDate", title: "Date", width: 140), Column(id: "rightSize", title: "Size", width: 90),
        Column(id: "rightName", title: "Name", width: 210)
    ]
    /// Dates in the short format with seconds (spec 09 › Result list).
    internal static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    /// What the window shows and works on.
    internal let session: SyncSession
    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// The folder panel and the pop-up of the saved sets.
    internal let effects: SyncWindowEffects

    /// The pop-up of the saved sets.
    internal let setsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The left directory, as typed or chosen.
    internal let leftField = NSTextField()
    /// The right directory, as typed or chosen.
    internal let rightField = NSTextField()
    /// The file masks.
    internal let maskField = NSTextField()
    /// "Compare", which becomes "Abort" while a comparison runs.
    internal let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    /// "Synchronize…".
    internal let synchronizeButton = NSButton(title: "Synchronize…", target: nil, action: nil)
    /// "Subdirs".
    internal let subdirsBox = NSButton(checkboxWithTitle: "Subdirs", target: nil, action: nil)
    /// "by content".
    internal let byContentBox = NSButton(checkboxWithTitle: "by content", target: nil, action: nil)
    /// "ignore date".
    internal let ignoreDateBox = NSButton(checkboxWithTitle: "ignore date", target: nil, action: nil)
    /// "Asymmetric".
    internal let asymmetricBox = NSButton(checkboxWithTitle: "Asymmetric", target: nil, action: nil)
    /// "Empty directories".
    internal let emptyDirectoriesBox = NSButton(checkboxWithTitle: "Empty directories", target: nil, action: nil)
    /// "Only selected (in main window)".
    internal let onlySelectedBox = NSButton(
        checkboxWithTitle: "Only selected (in main window)",
        target: nil,
        action: nil
    )
    /// "ignore 1 h difference".
    internal let oneHourBox = NSButton(checkboxWithTitle: "ignore 1 h difference", target: nil, action: nil)
    /// The time tolerance.
    internal let tolerancePopup = NSPopUpButton()
    /// The hours added to the dates of the right side.
    internal let offsetField = NSTextField()
    /// The Show buttons, each with the part of the filter it stands for.
    internal var showButtons: [(button: NSButton, part: SyncShow)] = []
    /// The subdirectory indicator next to the Show buttons.
    internal let indicatorLabel = NSTextField(labelWithString: "")
    /// The status line.
    internal let statusLabel = NSTextField(labelWithString: "")
    /// How far a comparison by content is.
    internal let progressBar = NSProgressIndicator()
    /// The result list.
    internal let table = KeyTableView()
    /// The context menu of the rows, made each time it opens.
    internal let rowMenu = NSMenu()

    /// Puts a window of the tool on screen.
    ///
    /// Tests replace it, so that no window shows in the session they run in, and look at what it
    /// was asked to show.
    internal var present: @MainActor (NSWindowController) -> Void = { controller in controller.showWindow(nil) }

    // MARK: Rows

    /// The session rows the commands act on: the selected ones.
    internal var selectedRows: [Int] {
        table.selectedRowIndexes.compactMap { position in
            guard session.entries.indices.contains(position), case .row(let index) = session.entries[position] else {
                return nil
            }
            return index
        }
    }

    /// A window for `session`, built but not shown, whose folder panel and menus are `effects`.
    internal init(session: SyncSession, effects: SyncWindowEffects) {
        self.session = session
        self.effects = effects
        kernel = session.kernel
        let window = ToolWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Synchronize directories"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 380)
        window.center()
        super.init(window: window)
        window.delegate = self
        // Esc interrupts a running comparison; when idle it closes the window.
        window.onEscape = { [weak self] in self?.interruptComparison() == true }
        buildContent(in: window)
        session.onChange = { [weak self] in self?.refresh() }
        session.onRowsChange = { [weak self] rows in self?.refreshRows(rows) }
    }

    /// The window is made in code, never from an archive.
    internal required init?(coder _: NSCoder) { nil }

    /// Shows the window with what the session holds now.
    internal func show() {
        // The list is drawn from this window again (closing let go of it).
        table.dataSource = self
        table.delegate = self
        pullControls()
        refresh()
        present(self)
        window?.makeFirstResponder(compareButton)
    }

    /// Esc: interrupts a running comparison and says so; false when nothing runs.
    internal func interruptComparison() -> Bool {
        guard session.phase == .comparing else {
            return false
        }
        session.cancelComparison()
        return true
    }

    /// Stops a running comparison and lets go of the session's list.
    internal func windowWillClose(_: Notification) {
        session.cancelComparison()
        // A closed window asks nothing more of the session, whose kernel may be gone before
        // the window's views are when the program ends; `show` takes the list up again.
        table.dataSource = nil
        table.delegate = nil
    }
}
