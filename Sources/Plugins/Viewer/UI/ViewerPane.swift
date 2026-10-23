import AFMKernel
import AppKit
import Foundation
import PDFKit
import QuickLookUI

/// A Lister: the menu strip, the content in one of the display modes and the status line
/// (spec 10 › The Lister window).
///
/// The Lister window holds one, the quick-view pane another.
///
/// Threading: the pane and its views belong to the main thread. Everything that touches a
/// file — opening it, detecting its type, indexing, fetching rows, searching, decoding images,
/// copying to the clipboard — runs on background queues and comes back with a generation
/// number; what was overtaken by a newer load is dropped. Each load has a cancellation flag
/// that stops the work of the one before.
///
/// The state is here; its extensions (loading, presenting, the menus, the keys, search, printing)
/// share it, on the main thread.
internal final class ViewerPane: NSView, NSMenuDelegate {
    /// A monitor of the application's key presses that is removed when it goes: whoever
    /// holds it can be sure the monitor never outlives it.
    private final class KeyMonitor {
        private let token: Any?

        init(_ handler: @escaping (NSEvent) -> NSEvent?) {
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        }

        deinit {
            _ = token.map(NSEvent.removeMonitor)
        }
    }

    // MARK: State

    /// What is known about the loaded file.
    internal struct Loaded {
        /// What was asked for.
        internal let item: ViewerItem
        /// Its bytes.
        internal let source: any ByteSource
        /// The first bytes, which the type and the encoding are told from.
        internal let sample: Data
        /// What the sample says about the text.
        internal let guess: ViewerDetection.TextGuess
        /// What kind of file it is: image, PDF, media, HTML, RTF or other.
        internal let content: ViewerDetection.Content
        /// Whether reading on several threads at once pays off (a local disk, memory).
        internal let parallel: Bool
    }

    /// A running search or other long work: what the status line shows, and how to stop it.
    internal struct Activity {
        /// What the status line says.
        internal var text: String
        /// How far it is, 0…1; nil when that cannot be told (the bar then spins).
        internal var progress: Double?
        /// Stops it (Esc, Cancel).
        internal var cancel: CancellationFlag
    }

    /// The menus of the strip, in their order.
    internal static let menuTitles = ["File", "Edit", "Options", "Encoding"]

    /// The most entries the quick view counts in a folder on a server.
    nonisolated internal static let remoteFolderEntryLimit = 20_000
    /// Files up to this size are read whole where a mode needs all of a file at once.
    nonisolated internal static let wholeFileLimit: Int64 = 1 << 30
    /// An HTML file is shown as a page up to this size (it is handed to the web view, a string
    /// of twice the size, on the main thread); beyond it the text modes show it.
    nonisolated internal static let htmlPageLimit: Int64 = 8 << 20
    /// An RTF file is shown formatted up to this size (its layout is done on the main thread).
    nonisolated internal static let rtfLimit: Int64 = 4 << 20
    /// An HTML file is shown with its tags removed up to this size; beyond it the tags are
    /// text, as in the plain text modes (removing them takes memory and time in proportion).
    internal static let htmlTextLimit: Int64 = 32 << 20

    /// The kernel the files are read through.
    internal let kernel: Kernel
    /// The Lister's options.
    internal let settings: ListerSettings
    /// True in the quick-view pane: Esc and Q do not close anything, and keys are taken only
    /// while the pane has the keyboard.
    internal let isEmbedded: Bool
    /// No Quick Look, no images, no multimedia (the specification's `cm_ListInternalOnly`).
    internal var internalOnly = false
    /// Where Copy puts its result.
    internal var pasteboard = NSPasteboard.general
    /// Where links that may be opened go: the browser, the mail program.
    internal var links: any LinkOpening = SystemLinks()
    /// The panels the pane asks with, and printing.
    internal var dialogs: any ViewerDialogs = SystemDialogs()
    /// What sounds and films are played with: the system's player, or a test's that plays nothing.
    internal var mediaPlayback: @MainActor () -> any MediaPlayback = { SystemMediaPlayback() }

    /// The window title changed (a file was loaded, a track names itself).
    internal var onTitleChange: (String) -> Void = { _ in
        // No title shows until the window sets this.
    }
    /// Asked to close the window (Esc, Q, F10).
    internal var onClose: () -> Void = {
        // Nothing closes until the window sets this.
    }
    /// Asked to step through the files of the session: +1 next, -1 previous.
    internal var onStep: (Int) -> Void = { _ in
        // A pane without a session has no other file.
    }
    /// Options › Configure….
    internal var onConfigure: () -> Void = {
        // Nothing to configure until the plugin sets this.
    }
    /// Options › Save position.
    internal var onSavePosition: () -> Void = {
        // Nothing to save until the window sets this.
    }
    /// Position and count of the file among those of the session, for `<< 1/3 >>`.
    internal var fileCounter: (index: Int, count: Int) = (0, 1) { didSet { updateChrome() } }

    /// What is shown, or being read; nil when nothing is.
    internal var item: ViewerItem?
    /// Why the file could not be opened, when it could not.
    internal var failure: String?
    /// What the folder shown by `showFolder` holds, once it has been counted.
    internal var folderSummary: FolderSummary?
    /// The file once it has been opened and sampled.
    internal var loaded: Loaded?
    /// The display mode (Options › 1…8).
    internal var mode = ViewMode.text
    /// The font of the Options menu.
    internal var fontSlot = FontSlot.ansi
    /// The Encoding menu's choice of code page; nil = as configured for the font.
    internal var codePage: ViewerEncoding?
    /// Num + / Num − change the font size for as long as the window lives; Ctrl+0 undoes it.
    internal var fontSizeChange = 0.0
    /// Counts the loads: what a background job of an earlier one brings back is dropped.
    internal var loadGeneration = 0
    /// Counts the calls of `present`: what a background job of an earlier one brings back is
    /// dropped, whatever the order the jobs finish in (the work queue is concurrent).
    internal var presentGeneration = 0
    /// Stops the background work of the last `present`.
    internal var presentCancellation = CancellationFlag()
    /// Stops the background work of the file shown; a new one is made for each load.
    internal var cancellation = CancellationFlag()
    /// Where the pane reads, decodes and searches, off the main thread.
    internal let workQueue = DispatchQueue(label: "viewer.work", qos: .userInitiated, attributes: .concurrent)
    /// How a file whose reads are slow (a server) is kept once read: in blocks of this size, this
    /// many of them in memory.
    ///
    /// A file that fits (64 MB) is kept whole, a bigger one on disk.
    internal var slowFileBlocks = (size: 256 << 10, count: 256)
    /// The local copies of files of other file systems, for the modes that need a file on disk.
    internal let temporaryCopies: TemporaryCopies
    /// The text of an HTML file with its tags removed, kept while the file is shown.
    internal var strippedHTML: (links: [String], source: any ByteSource)?
    /// The laying out again after a resize, once the size has settled.
    ///
    /// Set on the main thread, read in `deinit`.
    nonisolated(unsafe) internal var resizeWork: DispatchWorkItem?

    // MARK: Search state (see ViewerPane+Search)

    /// What was searched for last, and how.
    internal var lastSearch: (text: String, options: SearchOptions)?
    /// Whether the last search went backwards (Ctrl+F3 goes the other way).
    internal var lastSearchWentBackwards = false
    /// A running search or other long work: what the status line shows, and how to stop it.
    internal var activity: Activity? { didSet { updateChrome() } }

    // MARK: Views

    /// The text modes' view.
    internal let pager = TextPagerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    /// The image mode's view, while it shows an image.
    internal var imageView: ImageCanvasView?
    /// The media player, while it plays a file.
    internal var mediaView: MediaView?
    /// The PDF view, while it shows a PDF.
    internal var pdfView: PDFView?
    /// The web view, while it shows an HTML page.
    internal var webView: WebContentView?
    /// The text view, while it shows an RTF text.
    internal var richText: NSTextView?
    /// The Quick Look view, while it shows a preview.
    internal var previewView: QLPreviewView?
    /// The view the content area shows.
    internal var contentView: NSView?
    /// The content area, between the menu strip and the status line.
    internal let contentHost = NSView()
    /// The menus of the strip, as `menuTitles` names them.
    internal let menuButtons: [NSPopUpButton]
    /// `<<`: the previous file of the session.
    internal let previousButton = NSButton(title: "<<", target: nil, action: nil)
    /// `>>`: the next file of the session.
    internal let nextButton = NSButton(title: ">>", target: nil, action: nil)
    /// `1/3`: which file of the session is shown.
    internal let counterLabel = NSTextField(labelWithString: "")
    /// The position in a text or the zoom of an image; a click asks for a new one.
    internal let percentButton = NSButton(title: "100 %", target: nil, action: nil)
    /// The status line.
    internal let statusLabel = NSTextField(labelWithString: "")
    /// The progress of `activity`.
    internal let progressBar = NSProgressIndicator()
    /// Stops `activity`.
    internal let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// Set while the pane is in a window; it goes with the pane at the latest.
    private var keyMonitor: KeyMonitor?

    /// The pane takes the keyboard when it shows no text.
    override internal var acceptsFirstResponder: Bool { true }

    /// A pane that shows nothing yet; `load` gives it a file.
    internal init(kernel: Kernel, settings: ListerSettings, temporaryCopies: TemporaryCopies, isEmbedded: Bool) {
        self.kernel = kernel
        self.settings = settings
        self.temporaryCopies = temporaryCopies
        self.isEmbedded = isEmbedded
        menuButtons = Self.menuTitles.map { title in
            let button = NSPopUpButton(frame: .zero, pullsDown: true)
            button.isBordered = false
            button.addItem(withTitle: title)
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            return button
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 860, height: 620))
        buildChrome()
        pager.onStatusChange = { [weak self] in self?.updateChrome() }
        pager.onResize = { [weak self] in self?.pagerResized() }
        pager.onZoom = { [weak self] steps in self?.changeFontSize(by: Double(steps)) }
        pager.contextMenu = { [weak self] in self?.makeContextMenu() }
        applySettings()
    }

    /// Made in code only: an archive gives none.
    internal required init?(coder _: NSCoder) { nil }

    // MARK: Window

    /// In a window the pane watches the keys of the application; a Quick Look view is made anew.
    override internal func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyMonitor = nil
        guard window != nil else {
            return
        }
        // A Quick Look view closed when the pane left its window is made anew in this one.
        if mode == .preview, previewView == nil { present() }
        // The Lister keys are plain letters and keys the main window uses for other things;
        // they are taken before anything else sees them, but only for this pane's window and,
        // inside the main window, only while the pane has the keyboard (spec 10 › Embedded
        // Lister: "these keep their Lister meaning").
        // A key the pane handled is taken from the application (nil); the monitor is removed
        // when the pane leaves its window, and with the pane when it goes.
        keyMonitor = KeyMonitor { [weak self] event in self?.takes(event) == true ? nil : event }
    }

    /// A Quick Look view is closed before the pane leaves its window (closing one in no window ends the program).
    override internal func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard previewView != nil, newWindow !== window else {
            return
        }
        closePreview()
        showMessage("")
    }

    /// The end of a live resize lays a text wrapped at the window's edge out anew.
    override internal func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        pagerResized()
    }

    /// Fills a menu of the strip as it opens.
    internal func menuNeedsUpdate(_ menu: NSMenu) {
        guard let index = menuButtons.firstIndex(where: { $0.menu === menu }) else {
            return
        }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        fill(menu, with: menuEntries(Self.menuTitles[index]))
    }

    deinit {
        cancellation.cancel()
        presentCancellation.cancel()
        resizeWork?.cancel()
        temporaryCopies.release(owner: ObjectIdentifier(self))
    }
}
