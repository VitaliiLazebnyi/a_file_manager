import AFMKernel
import AFMShell
import AppKit

/// The "Compare contents" window (spec 09 › Compare by content › Window): two panes that
/// scroll and select together, one row per line of the comparison.
///
/// It draws a `CompareSession` and forwards clicks and keys to it; nothing here reads a file. Main
/// thread only.
internal final class CompareWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    /// What the window shows and works on.
    internal let session: CompareSession
    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// The settings of Compare by content (below `compareContent.`): the font and the layout.
    internal let settings: any SettingsStore
    /// Called when the window has closed, so that the plugin lets go of it.
    private let onClose: (CompareWindowController) -> Void
    /// The beep, the file and font panels, the clipboard and the showing of the window.
    internal let effects: CompareWindowEffects
    /// The window, which the controller has from its start to its end.
    internal let toolWindow: ToolWindow

    /// The path of the left file, as typed or chosen.
    internal let leftField = NSTextField()
    /// The path of the right file, as typed or chosen.
    internal let rightField = NSTextField()
    /// What to search for in both files.
    internal let searchField = NSSearchField()
    /// "Binary": hex comparison also for text files.
    internal let binaryBox = NSButton(checkboxWithTitle: "Binary", target: nil, action: nil)
    /// The bytes per row in binary mode.
    internal let bytesPopup = NSPopUpButton()
    /// "Ignore case".
    internal let caseBox = NSButton(checkboxWithTitle: "Ignore case", target: nil, action: nil)
    /// "Ignore repeated spaces".
    internal let spacesBox = NSButton(checkboxWithTitle: "Ignore repeated spaces", target: nil, action: nil)
    /// "Ignore line-end differences".
    internal let endingsBox = NSButton(checkboxWithTitle: "Ignore line-end differences", target: nil, action: nil)
    /// Whether the panes are above each other instead of side by side.
    internal let verticalBox = NSButton(checkboxWithTitle: "Above each other", target: nil, action: nil)
    /// "Edit mode".
    internal let editBox = NSButton(checkboxWithTitle: "Edit mode", target: nil, action: nil)
    /// Copy -> and Copy <- and Undo, shown in edit mode only; Undo is the last.
    internal var editButtons: [NSButton] = []
    /// Next and Previous difference, enabled while there are differences.
    internal var differenceButtons: [NSButton] = []
    /// "Save", enabled while there are edits that are not saved.
    internal let saveButton = NSButton(title: "Save", target: nil, action: nil)
    /// The status line under the panes.
    internal let statusLabel = NSTextField(labelWithString: "")
    /// Holds the two panes, side by side or above each other.
    internal let split = NSSplitView()
    /// The pane of the left file.
    internal let leftTable = PaneTableView()
    /// The pane of the right file.
    internal let rightTable = PaneTableView()
    /// The font of the panes, chosen in the font panel and remembered.
    internal var font: NSFont
    /// Set while one pane follows the other, so that the change it makes is not followed back.
    internal var isMirroring = false
    /// Whether the next comparison that comes selects its first difference.
    internal var jumpsToFirstDifference = true
    /// The lines marked for "Resync comparison from here", as rows.
    internal var resyncMarks: (left: Int?, right: Int?) = (nil, nil)
    /// The folder typed paths are relative to: the folder of the files compared first.
    internal var base = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Moving around

    /// The row of the cursor: the selected row, else the first row shown.
    internal var currentRow: Int {
        leftTable.selectedRow >= 0 ? leftTable.selectedRow : max(0, leftTable.rows(in: leftTable.visibleRect).location)
    }

    /// The pane the keyboard is in.
    internal var focusedSide: CompareSide {
        window?.firstResponder === rightTable ? .right : .left
    }

    // MARK: Editing

    /// The rows "Copy" works on: the selected rows when several are, else the difference the
    /// cursor is in, else the cursor's row.
    internal var rowsToCopy: Range<Int>? {
        let selection = leftTable.selectedRowIndexes
        guard let first = selection.first, let last = selection.last else {
            return nil
        }
        if selection.count > 1 {
            return first..<(last + 1)
        }
        return session.block(containing: first) ?? first..<(first + 1)
    }

    /// A window for `session`, built but not shown; `onClose` is called once it has closed.
    internal init(
        session: CompareSession,
        effects: CompareWindowEffects,
        onClose: @escaping (CompareWindowController) -> Void
    ) {
        self.session = session
        self.effects = effects
        self.onClose = onClose
        kernel = session.kernel
        settings = kernel.settings.scoped(to: CompareSettingsKey.scope)
        let size = CGFloat(Double(settings.text(CompareSettingsKey.fontSize, default: "12")) ?? 12)
        font =
            NSFont(name: settings.text(CompareSettingsKey.fontName, default: ""), size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let window = ToolWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Compare contents"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 360)
        window.center()
        toolWindow = window
        super.init(window: window)
        window.delegate = self
        // Esc interrupts a running comparison; when idle it closes the window.
        window.onEscape = { [weak self] in self?.stopsComparison() == true }
        buildContent(in: window)
        session.onChange = { [weak self] in self?.refresh() }
    }

    /// Not made from an archive.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// Esc: stops a comparison that runs, and says so; false when none runs (Esc then closes the window).
    internal func stopsComparison() -> Bool {
        guard session.phase == .working else {
            return false
        }
        session.cancel()
        return true
    }

    /// Fills the controls from the session and puts the window on the desktop, the left pane in focus.
    internal func show() {
        if let url = session.leftURL ?? session.rightURL {
            base = url.deletingLastPathComponent()
        }
        pullControls()
        refresh()
        effects.present(self)
        window?.makeFirstResponder(leftTable)
    }

    // MARK: Window

    /// Closes at once without unsaved edits; else asks first (Save, Don't Save or Cancel) and closes after.
    internal func windowShouldClose(_: NSWindow) -> Bool {
        guard session.hasUnsavedChanges else {
            return true
        }
        // Closing this way does not ask again; whatever was not saved is given up.
        whenChangesAreSettled { [weak self] in self?.close() }
        return false
    }

    /// Stops following the panes and the font panel, cancels the session's work and tells the plugin.
    internal func windowWillClose(_: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if NSFontManager.shared.target === self {
            NSFontManager.shared.target = nil
        }
        session.cancel()
        onClose(self)
    }
}
