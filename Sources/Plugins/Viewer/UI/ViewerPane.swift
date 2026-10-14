import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import PDFKit
import Quartz

/// What a viewer is asked to show: a file on any file system, or a text that is not a file.
struct ViewerItem {
    enum Source {
        case file(URL)
        case text(String)
    }

    let source: Source
    let title: String

    var url: URL? {
        if case .file(let url) = source { return url }
        return nil
    }
}

/// A Lister: the menu strip, the content in one of the display modes and the status line
/// (spec 10 › The Lister window). The Lister window holds one, the quick-view pane another.
///
/// Threading: the pane and its views belong to the main thread. Everything that touches a
/// file — opening it, detecting its type, indexing, fetching rows, searching, decoding images,
/// copying to the clipboard — runs on background queues and comes back with a generation
/// number; what was overtaken by a newer load is dropped. Each load has a cancellation flag
/// that stops the work of the one before.
final class ViewerPane: NSView, NSMenuDelegate {
    let kernel: Kernel
    let settings: ListerSettings
    /// True in the quick-view pane: Esc and Q do not close anything, and keys are taken only
    /// while the pane has the keyboard.
    let isEmbedded: Bool
    /// No Quick Look, no images, no multimedia (the specification's `cm_ListInternalOnly`).
    var internalOnly = false
    /// Where Copy puts its result.
    var pasteboard = NSPasteboard.general

    /// The window title changed (a file was loaded, a track names itself).
    var onTitleChange: (String) -> Void = { _ in }
    /// Asked to close the window (Esc, Q, F10).
    var onClose: () -> Void = {}
    /// Asked to step through the files of the session: +1 next, -1 previous.
    var onStep: (Int) -> Void = { _ in }
    /// Options › Configure… and Save position.
    var onConfigure: () -> Void = {}
    var onSavePosition: () -> Void = {}
    /// Position and count of the file among those of the session, for `<< 1/3 >>`.
    var fileCounter: (index: Int, count: Int) = (0, 1) { didSet { updateChrome() } }

    // MARK: State

    /// What is known about the loaded file.
    struct Loaded {
        let item: ViewerItem
        let source: ByteSource
        let sample: Data
        let guess: ViewerDetection.TextGuess
        let content: ViewerDetection.Content
        /// Whether reading on several threads at once pays off (a local disk, memory).
        let parallel: Bool
    }

    private(set) var item: ViewerItem?
    /// Why the file could not be opened, when it could not.
    private(set) var failure: String?
    /// What the folder shown by `showFolder` holds, once it has been counted.
    private(set) var folderSummary: FolderSummary?
    private(set) var loaded: Loaded?
    var mode = ViewMode.text
    var fontSlot = FontSlot.ansi
    /// The Encoding menu's choice of code page; nil = as configured for the font.
    var codePage: ViewerEncoding?
    /// Num + / Num − change the font size for as long as the window lives; Ctrl+0 undoes it.
    var fontSizeChange = 0.0
    var loadGeneration = 0
    /// Counts the calls of `present`: what a background job of an earlier one brings back is
    /// dropped, whatever the order the jobs finish in (the work queue is concurrent).
    private(set) var presentGeneration = 0
    private var presentCancellation = CancellationFlag()
    var cancellation = CancellationFlag()
    let workQueue = DispatchQueue(label: "viewer.work", qos: .userInitiated, attributes: .concurrent)
    private let temporaryCopies: TemporaryCopies
    /// The text of an HTML file with its tags removed, kept while the file is shown.
    private var strippedHTML: (links: [String], source: ByteSource)?
    private var resizeWork: DispatchWorkItem?

    // MARK: Search state (see ViewerPane+Actions)

    var lastSearch: (text: String, options: SearchOptions)?
    var lastSearchWentBackwards = false
    /// A running search or other long work: what the status line shows, and how to stop it.
    var activity: (text: String, progress: Double?, cancel: CancellationFlag)? { didSet { updateChrome() } }

    // MARK: Views

    let pager = TextPagerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    private(set) var imageView: ImageCanvasView?
    private(set) var mediaView: MediaView?
    private(set) var pdfView: PDFView?
    private(set) var webView: WebContentView?
    private(set) var richText: NSTextView?
    private var previewView: QLPreviewView?
    private var contentView: NSView?
    private let contentHost = NSView()
    private let menuButtons: [NSPopUpButton]
    private let previousButton = NSButton(title: "<<", target: nil, action: nil)
    private let nextButton = NSButton(title: ">>", target: nil, action: nil)
    private let counterLabel = NSTextField(labelWithString: "")
    private let percentButton = NSButton(title: "100 %", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var keyMonitor: Any?
    static let menuTitles = ["File", "Edit", "Options", "Encoding"]

    init(kernel: Kernel, settings: ListerSettings, temporaryCopies: TemporaryCopies, isEmbedded: Bool) {
        self.kernel = kernel
        self.settings = settings
        self.temporaryCopies = temporaryCopies
        self.isEmbedded = isEmbedded
        menuButtons = ViewerPane.menuTitles.map { title in
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
        pager.onZoom = { [weak self] in self?.changeFontSize(by: Double($0)) }
        pager.contextMenu = { [weak self] in self?.makeContextMenu() }
        applySettings()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        cancellation.cancel()
        presentCancellation.cancel()
        resizeWork?.cancel()
        temporaryCopies.release(owner: ObjectIdentifier(self))
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: Layout

    private func buildChrome() {
        for button in menuButtons { button.menu?.delegate = self }
        for (button, action) in [
            (previousButton, #selector(previousFile)), (nextButton, #selector(nextFile)),
            (percentButton, #selector(percentClicked)),
            (cancelButton, #selector(cancelActivity))
        ] {
            button.target = self
            button.action = action
            button.isBordered = button === cancelButton
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        percentButton.toolTip = "Go to position (in %)"
        counterLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        cancelButton.isHidden = true
        let spacer = NSView()
        let statusSpacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let strip = NSStackView(views: menuButtons + [spacer, previousButton, counterLabel, nextButton, percentButton])
        strip.spacing = 6
        strip.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 8)
        let status = NSStackView(views: [statusLabel, statusSpacer, progressBar, cancelButton])
        status.spacing = 8
        status.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        progressBar.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let stack = NSStackView(views: [strip, contentHost, status])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentHost.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        contentHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// Puts a view into the content area in place of the one before.
    private func setContent(_ view: NSView, keyboardTo responder: NSView? = nil) {
        if contentView !== view {
            contentView?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor)
            ])
            contentView = view
        }
        if !isEmbedded || hasKeyboard { window?.makeFirstResponder(responder ?? self) }
    }

    override var acceptsFirstResponder: Bool { true }

    /// Whether the keyboard is somewhere inside the pane.
    var hasKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// Gives the pane the keyboard: to the text when it shows text.
    func takeKeyboard() {
        window?.makeFirstResponder(contentView === pager ? pager : self)
    }

    // MARK: Keys

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard window != nil else { return }
        // The Lister keys are plain letters and keys the main window uses for other things;
        // they are taken before anything else sees them, but only for this pane's window and,
        // inside the main window, only while the pane has the keyboard (spec 10 › Embedded
        // Lister: "these keep their Lister meaning").
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.attachedSheet == nil,
                !self.isEmbedded || self.hasKeyboard,
                !(window.firstResponder is NSText) || self.richText === window.firstResponder
            else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    // MARK: Loading

    /// Shows a file or a text. Returns at once; the content appears when it has been read.
    func load(_ item: ViewerItem) {
        stopWork()
        self.item = item
        loaded = nil
        failure = nil
        folderSummary = nil
        strippedHTML = nil
        codePage = nil
        onTitleChange(item.title)
        let generation = loadGeneration
        let cancellation = cancellation
        let fileSystems = kernel.fileSystems
        let media = settings.additionalMediaTypes
        let vetoed = settings.noMediaTypes
        updateChrome()
        workQueue.async { [weak self] in
            // Moved on before this got a thread (the cursor ran over many files): nothing to read.
            guard !cancellation.isCancelled else { return }
            /// Opens and samples the file. `flag` ends it: the pane's own, or, for a file system, the one
            /// `BlockingCalls` hands over once nobody waits for the answer.
            func open(_ item: ViewerItem, _ flag: CancellationFlag) -> Result<Loaded, Error> {
                Result { () -> Loaded in
                    switch item.source {
                    case .text(let text):
                        let data = Data(text.utf8)
                        return Loaded(
                            item: item, source: DataByteSource(data), sample: data.prefix(ViewerDetection.sampleSize),
                            guess: ViewerDetection.TextGuess(encoding: .utf8), content: .other, parallel: true)
                    case .file(let url):
                        let provider = try fileSystems.provider(for: url)
                        // What a plugin still holds back for this file (an archive written after a delay) is written first.
                        try fileSystems.flushPendingWrites(to: url, cancellation: flag)
                        if provider.item(at: url, cancellation: flag)?.isDirectory == true {
                            throw FileSystemError.notSupported("Viewing a folder")
                        }
                        let opened = try ProviderByteSource.open(url, fileSystems: fileSystems, cancellation: flag)
                        let isLocal =
                            opened is DataByteSource
                            || (provider.volume(of: url, cancellation: flag)?.isLocal ?? false)
                        // Where a read is slow (a server), a file up to 64 MB is kept whole once it has
                        // been read, and a bigger one on disk, so laying the text out again does not
                        // fetch it again.
                        let source =
                            isLocal
                            ? CachedByteSource(opened)
                            : CachedByteSource(
                                opened, blockSize: 256 << 10, capacity: 256, wholeFileLimit: 64 << 20,
                                spillsToDisk: true)
                        let sample = try source.read(at: 0, count: ViewerDetection.sampleSize, cancellation: flag)
                        return Loaded(
                            item: item, source: source, sample: sample,
                            guess: ViewerDetection.guessText(
                                sample, isWholeFile: Int64(sample.count) >= source.length),
                            content: ViewerDetection.content(
                                name: url.lastPathComponent, sample: sample, additionalMedia: media, vetoed: vetoed),
                            parallel: isLocal)
                    }
                }
            }
            // A file system that does not answer must not hold this thread: the work is asked of a
            // kernel thread (at most 64 per file system), and this thread goes on once the file is no
            // longer wanted, whatever the file system does.
            let result: Result<Loaded, Error>
            if case .file(let url) = item.source, let provider = try? fileSystems.provider(for: url) {
                let answer = BlockingCalls.answer(
                    from: provider, to: "view " + url.absoluteString, sharing: false, cancellation: cancellation
                ) { flag in
                    open(item, flag)
                }
                guard let answer else { return }
                result = answer
            } else {
                result = open(item, cancellation)
            }
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation, !cancellation.isCancelled else {
                    ViewerCleanup.close((try? result.get())?.source)
                    return
                }
                switch result {
                case .success(let loaded):
                    self.loaded = loaded
                    self.chooseStartupMode(for: loaded)
                    self.present()
                case .failure(let error):
                    self.failure = error.localizedDescription
                    self.showMessage(error.localizedDescription)
                }
            }
        }
    }

    /// Reads the file again (F2).
    func reload() {
        if let item { load(item) }
    }

    /// Stops whatever the pane is doing for the file it shows and lets go of the file.
    func stopWork() {
        cancellation.cancel()
        cancellation = CancellationFlag()
        presentCancellation.cancel()
        resizeWork?.cancel()
        resizeWork = nil
        temporaryCopies.release(owner: ObjectIdentifier(self))
        loadGeneration += 1
        activity?.cancel.cancel()
        activity = nil
        mediaView?.stop()
        // Rows and the index of the text shown wait on the file system too.
        pager.stopReading()
        // Closing a reader of a server waits for it: not here, on the main thread.
        ViewerCleanup.close(loaded?.source)
    }

    /// Shows nothing (the quick view between two files).
    func clear(message: String = "") {
        stopWork()
        item = nil
        loaded = nil
        folderSummary = nil
        showMessage(message)
    }

    /// Shows what a folder holds instead of a file (spec 03 › Quick View: on a folder,
    /// information about its occupied space). The folder is counted in the background, on all
    /// cores; moving on to something else stops the counting.
    func showFolder(_ url: URL, name: String) {
        clear(message: "\(name)\n\nCounting…")
        let generation = loadGeneration
        let cancellation = cancellation
        let fileSystems = kernel.fileSystems
        workQueue.async { [weak self] in
            guard !cancellation.isCancelled, let provider = try? fileSystems.provider(for: url) else { return }
            // A tree on a server is a trip per folder: the quick view counts a part of it only.
            let isLocal = provider.volume(of: url, cancellation: cancellation)?.isLocal ?? true
            let summary = FolderSummary.measure(
                url, provider: provider, cancellation: cancellation,
                limit: isLocal ? nil : ViewerPane.remoteFolderEntryLimit)
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation, !cancellation.isCancelled else { return }
                self.folderSummary = summary
                self.showMessage("\(name)\n\n\(summary.text)")
            }
        }
    }

    func showMessage(_ text: String) {
        pager.clear()
        dropRichViews()
        setContent(RichViews.message(text))
        updateChrome()
    }

    private func dropRichViews() {
        mediaView?.stop()
        // A Quick Look view has a window of its own until it is closed.
        previewView?.close()
        previewView = nil
        (imageView, mediaView, pdfView, webView, richText) = (nil, nil, nil, nil, nil)
    }

    /// The mode a file opens in (spec 10 › Reference algorithm).
    private func chooseStartupMode(for loaded: Loaded) {
        let ext = loaded.item.url?.pathExtension.lowercased() ?? ""
        switch settings.startupFont {
        case 1: fontSlot = .ansi
        case 2: fontSlot = .ascii
        case 3: fontSlot = .variable
        default: fontSlot = loaded.guess.encoding == .dos ? .ascii : .ansi
        }
        mode = startupTextMode(for: loaded)
        guard !internalOnly, loaded.item.url != nil else { return }
        if settings.loadsGraphics, loaded.content == .image || loaded.content == .pdf {
            mode = .media
        } else if settings.playsMultimedia, loaded.content == .media {
            mode = .media
        } else if settings.usesQuickLook, settings.quickLookTypes.contains(ext), !settings.noMediaTypes.contains(ext) {
            mode = .preview
        } else if settings.showsRTF, loaded.content == .rtf {
            mode = .media
        } else if settings.showsHTMLAsText, loaded.content == .html {
            mode = .html
        }
    }

    private func startupTextMode(for loaded: Loaded) -> ViewMode {
        switch settings.startupMode {
        case 2: return .binary
        case 3: return .hex
        case 0 where loaded.guess.isBinary: return .binary
        default:
            switch loaded.guess.encoding.kind {
            case .utf8: return .utf8
            case .utf16LE, .utf16BE: return .unicode
            default: return .text
            }
        }
    }

    // MARK: Presenting

    /// Switches the display mode (Options › 1…8).
    func setMode(_ newMode: ViewMode) {
        guard loaded != nil else { return }
        // 4 again goes on to the next way of showing the file (the specification cycles
        // through the plugins; here that is Quick Look).
        mode = newMode == .media && mode == .media && settings.usesQuickLook && !internalOnly ? .preview : newMode
        present()
    }

    /// The encoding the current mode shows text in.
    var encoding: ViewerEncoding {
        guard let loaded else { return .utf8 }
        switch mode {
        case .utf8: return .utf8
        case .unicode:
            if let codePage, codePage.unitSize == 2 { return codePage }
            return loaded.guess.encoding.unitSize == 2 ? loaded.guess.encoding : .utf16LE
        case .html where strippedHTML != nil: return .utf8
        default: return codePage ?? fontSlot.encoding
        }
    }

    var currentFont: NSFont {
        let slot: FontSlot = fontSlot == .variable && mode != .binary && mode != .hex ? .variable : .ansi
        let chosen = settings.font(slot)
        let size = CGFloat(min(96, max(6, chosen.size + fontSizeChange)))
        if let name = chosen.name, let font = NSFont(name: name, size: size) { return font }
        return slot == .variable ? .systemFont(ofSize: size) : .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// How the current mode lays out its rows.
    var layout: ViewerLayout {
        switch mode {
        case .binary: return .binary(width: settings.binaryWidth)
        case .hex: return .hex
        default:
            guard settings.wrap else {
                return .text(
                    TextLayoutOptions(columns: settings.unwrapWidth, wordWrap: false, tabWidth: settings.tabWidth))
            }
            let columns = settings.textWidth > 0 ? settings.textWidth : pager.columnsThatFit
            return .text(TextLayoutOptions(columns: columns, wordWrap: true, tabWidth: settings.tabWidth))
        }
    }

    /// Shows the loaded file in the current mode.
    func present(keeping offset: Int64? = nil) {
        guard let loaded else { return }
        presentGeneration += 1
        presentCancellation.cancel()
        presentCancellation = CancellationFlag()
        if mode == .html, strippedHTML == nil {
            stripHTML(loaded)
            return
        }
        if mode.isTextual {
            dropRichViews()
            pager.font = currentFont
            pager.showsCaret = settings.caret
            pager.searchGoBack = settings.searchGoBack
            setContent(pager, keyboardTo: pager)
            // The width decides where a text wrapped at the window's edge is cut.
            if window != nil { layoutSubtreeIfNeeded() }
            let source = mode == .html ? strippedHTML?.source ?? loaded.source : loaded.source
            let hasMark = mode != .html && ViewerDetection.byteOrderMark(loaded.sample)?.encoding == encoding
            // The text laid out before is given: what is the same in both is not read again.
            let document = TextDocument(
                source: source, encoding: encoding, bomLength: hasMark ? loaded.guess.bomLength : 0, layout: layout,
                reusing: pager.document)
            pager.show(
                document, at: offset ?? 0, keepingSelection: offset != nil && pager.document?.source === source,
                parallel: loaded.parallel)
        } else {
            pager.clear()
            presentRich(loaded)
        }
        updateChrome()
    }

    /// Reads an HTML file whole, removes its tags off the main thread and shows the text. A file
    /// beyond `htmlTextLimit` is shown as plain text instead.
    private func stripHTML(_ loaded: Loaded) {
        let generation = loadGeneration
        let token = presentGeneration
        let cancel = presentCancellation
        let braces = settings.linkBraces
        let encoding =
            ViewerDetection.htmlCharset(loaded.sample)
            ?? (loaded.guess.encoding.isUnicode ? loaded.guess.encoding : codePage ?? fontSlot.encoding)
        guard loaded.source.length <= ViewerPane.htmlTextLimit else {
            mode = startupTextMode(for: loaded)
            present()
            return
        }
        workQueue.async { [weak self] in
            let range = Int64(loaded.guess.bomLength)..<loaded.source.length
            let data: Data
            do {
                data = try loaded.source.read(range, cancellation: cancel)
                if Int64(data.count) < range.upperBound - range.lowerBound { throw ViewerError.fileChanged }
            } catch {
                guard !cancel.isCancelled else { return }
                DispatchQueue.main.async {
                    guard let self, self.loadGeneration == generation, self.presentGeneration == token,
                        self.mode == .html
                    else { return }
                    self.failure = error.localizedDescription
                    self.showMessage(error.localizedDescription)
                }
                return
            }
            guard !cancel.isCancelled,
                let result = HTMLText.plainText(
                    units: encoding.units(from: data), linkBraces: braces, cancellation: cancel)
            else { return }
            let stripped = DataByteSource(Data(result.text.utf8))
            DispatchQueue.main.async {
                // The mode may have been changed while the tags were removed: then this is not wanted.
                guard let self, self.loadGeneration == generation, self.presentGeneration == token, self.mode == .html
                else { return }
                self.strippedHTML = (result.links, stripped)
                self.present()
            }
        }
    }

    /// The text of an HTML file shown as text is cut again from its bytes the next time (after
    /// another encoding was chosen).
    func redecodeHTML() {
        if mode == .html { strippedHTML = nil }
    }

    /// The links of the HTML file that is shown as text.
    var htmlLinks: [String] { mode == .html ? strippedHTML?.links ?? [] : [] }

    /// The most entries the quick view counts in a folder on a server.
    static let remoteFolderEntryLimit = 20_000
    /// Files up to this size are read whole where a mode needs all of a file at once.
    static let wholeFileLimit: Int64 = 1 << 30
    /// An HTML file is shown as a page up to this size (it is handed to the web view, a string
    /// of twice the size, on the main thread); beyond it the text modes show it.
    static let htmlPageLimit: Int64 = 8 << 20
    /// An RTF file is shown formatted up to this size (its layout is done on the main thread).
    static let rtfLimit: Int64 = 4 << 20
    /// An HTML file is shown with its tags removed up to this size; beyond it the tags are
    /// text, as in the plain text modes (removing them takes memory and time in proportion).
    static let htmlTextLimit: Int64 = 32 << 20

    /// Image, PDF, media, HTML page, RTF or Quick Look: read or copied in the background,
    /// shown when ready.
    private func presentRich(_ loaded: Loaded) {
        dropRichViews()
        guard let url = loaded.item.url else {
            showMessage("A text that is not a file can only be shown as text.")
            return
        }
        setContent(RichViews.message("Loading…"))
        let generation = loadGeneration
        let cancellation = cancellation
        let token = presentGeneration
        let presentCancel = presentCancellation
        let content = mode == .preview ? ViewerDetection.Content.other : loaded.content
        let minimumDelay = settings.gifMinimumDelay
        let fileSystems = kernel.fileSystems
        let copies = temporaryCopies
        let htmlEncoding = ViewerDetection.htmlCharset(loaded.sample) ?? loaded.guess.encoding
        enum Ready {
            case image(DecodedImage)
            case pdf(PDFDocument)
            case html(String)
            case rtf(NSAttributedString)
            case local(URL)
            case failed(String)
            /// Too big to lay out on the main thread: the text modes show it.
            case asText
        }
        let length = loaded.source.length
        let owner = ObjectIdentifier(self)
        /// Whether what a job brings back is still wanted.
        func isCurrent(_ pane: ViewerPane) -> Bool {
            pane.loadGeneration == generation && pane.presentGeneration == token && !cancellation.isCancelled
                && !presentCancel.isCancelled && !pane.mode.isTextual
        }
        workQueue.async { [weak self] in
            // A file on the local disk is read by the framework that shows it, as far as it needs;
            // only other file systems are read whole into memory here.
            func whole() -> Data? {
                guard loaded.source.length <= ViewerPane.wholeFileLimit else { return nil }
                if url.isFileURL { return try? Data(contentsOf: url, options: .mappedIfSafe) }
                return try? loaded.source.read(0..<loaded.source.length, cancellation: presentCancel)
            }
            var ready = Ready.failed("The file cannot be shown in this mode.")
            switch content {
            case .image:
                // An animation shows its first frame while the others are still being decoded.
                let early: (DecodedImage) -> Void = { first in
                    DispatchQueue.main.async {
                        guard let self, isCurrent(self), self.imageView == nil else { return }
                        self.showImage(first)
                    }
                }
                let image =
                    url.isFileURL
                    ? ImageDecoder.decode(
                        contentsOf: url, minimumDelay: minimumDelay, cancellation: presentCancel, firstFrame: early)
                    : whole().flatMap {
                        ImageDecoder.decode(
                            $0, minimumDelay: minimumDelay, cancellation: presentCancel, firstFrame: early)
                    }
                if let image { ready = .image(image) }
            case .pdf:
                let document = url.isFileURL ? PDFDocument(url: url) : whole().flatMap(PDFDocument.init(data:))
                if let document { ready = .pdf(document) }
            case .html:
                if length > ViewerPane.htmlPageLimit {
                    ready = .asText
                } else if let data = whole() {
                    ready = .html(htmlEncoding.string(from: data))
                }
            case .rtf:
                if length > ViewerPane.rtfLimit {
                    ready = .asText
                } else if let text = whole().flatMap({ NSAttributedString(rtf: $0, documentAttributes: nil) }) {
                    ready = .rtf(text)
                }
            case .media, .other:
                switch copies.localCopy(for: url, fileSystems: fileSystems, owner: owner, cancellation: presentCancel) {
                case .success(let local): ready = .local(local)
                case .failure(let refusal): ready = refusal.isCancelled ? ready : .failed(refusal.message)
                }
            }
            DispatchQueue.main.async {
                guard let self, isCurrent(self) else { return }
                switch ready {
                case .image(let image):
                    if let view = self.imageView {
                        view.replaceFrames(with: image)
                        self.updateChrome()
                        return
                    }
                    self.showImage(image)
                    return
                case .pdf(let document):
                    let view = RichViews.pdfView(document)
                    self.pdfView = view
                    self.setContent(view)
                case .html(let html):
                    let view = WebContentView(frame: self.contentHost.bounds)
                    view.onLink = { [weak self] in self?.followLink($0) }
                    self.webView = view
                    self.setContent(view)
                    view.show(html: html)
                case .rtf(let text):
                    let views = RichViews.textView(text)
                    self.richText = views.text
                    self.setContent(views.scroll)
                case .local(let local) where content == .media:
                    let view = MediaView(frame: self.contentHost.bounds)
                    view.onEnd = { [weak self] in self?.onStep(1) }
                    view.onTitle = { [weak self] in self?.onTitleChange($0) }
                    self.mediaView = view
                    self.setContent(view)
                    view.play(local, volume: self.settings.playerVolume)
                case .local(let local):
                    if self.settings.usesQuickLook, !self.internalOnly, let view = RichViews.quickLookView(local) {
                        self.previewView = view
                        self.setContent(view)
                    } else {
                        self.showMessage("This is not an image or a multimedia file. Choose a text mode (1, 2 or 3).")
                    }
                case .failed(let reason):
                    self.showMessage(reason)
                case .asText:
                    self.mode = self.startupTextMode(for: loaded)
                    self.present()
                    return
                }
                self.updateChrome()
            }
        }
    }

    /// Puts an image (or the first frame of an animation) on the screen.
    private func showImage(_ image: DecodedImage) {
        let view = ImageCanvasView(frame: contentHost.bounds)
        view.fit = settings.imageFit
        view.centered = settings.centersImages
        view.onZoomChange = { [weak self] in self?.updateChrome() }
        imageView = view
        setContent(view)
        view.show(image)
        updateChrome()
    }

    /// A link in an HTML page, after a click on it: a page elsewhere opens in the browser, a
    /// file below the folder of this one in the viewer (spec 10 › HTML text). Nothing else is
    /// followed: a page cannot make the viewer open another server, another folder, or a local
    /// file it does not sit beside.
    func followLink(_ link: URL) {
        if LinkPolicy.opensInBrowser(link) {
            NSWorkspace.shared.open(link)
        } else if let base = item?.url, let target = LinkPolicy.target(of: link, relativeTo: base) {
            load(ViewerItem(source: .file(target), title: kernel.fileSystems.displayPath(target)))
        }
    }

    // MARK: Laying out again

    /// A text wrapped at the window's edge is cut anew when the width changed, once it has
    /// stopped changing (a quarter of a second without a new size, and the window's edge let
    /// go of), with the same text at the top.
    private func pagerResized() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeWork = nil
            // The end of the live resize asks again.
            guard !self.inLiveResize, !self.pager.inLiveResize else { return }
            guard self.contentView === self.pager, self.pager.shownLayout != nil, self.pager.shownLayout != self.layout
            else { return }
            self.present(keeping: self.pager.topOffset)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        pagerResized()
    }

    /// Shows the text again after an option changed, keeping the place.
    func relayout() {
        guard mode.isTextual, loaded != nil else { return }
        present(keeping: pager.document != nil ? pager.topOffset : nil)
    }

    func changeFontSize(by delta: Double) {
        fontSizeChange = delta == 0 ? 0 : min(60, max(-8, fontSizeChange + delta))
        pager.font = currentFont
        // A size that does not change the columns (a fixed width) needs no new index; one that
        // does is laid out once the size has stopped changing (each step of a zoom would start
        // an index of the whole file).
        if pager.shownLayout != layout { pagerResized() }
    }

    /// Takes over what was changed in the configuration.
    func applySettings() {
        pager.showsCaret = settings.caret
        pager.searchGoBack = settings.searchGoBack
        imageView?.fit = settings.imageFit
        imageView?.centered = settings.centersImages
        if loaded != nil, mode.isTextual, contentView === pager {
            pager.font = currentFont
            if pager.shownLayout != layout { relayout() }
        }
        updateChrome()
    }

    // MARK: Menu strip and status line

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let index = menuButtons.firstIndex(where: { $0.menu === menu }) else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        fill(menu, with: menuEntries(ViewerPane.menuTitles[index]))
    }

    /// The titles of the entries of one of the menus, for tests.
    func menuTitles(_ menu: String) -> [String] { menuEntries(menu).map { $0?.title ?? "-" } }

    @objc private func previousFile() { onStep(-1) }
    @objc private func nextFile() { onStep(1) }
    @objc private func percentClicked() { goToPercent() }
    @objc private func cancelActivity() { activity?.cancel.cancel() }

    /// What the percent item shows: the position in a text, the zoom of an image (spec 10 ›
    /// Position and zoom item).
    var percentText: String {
        if let imageView { return String(format: "%.1f %%", imageView.zoom * 100) }
        if contentView === pager, pager.document != nil { return String(format: "%.0f %%", pager.percent) }
        return ""
    }

    var statusText: String {
        if let activity { return activity.text }
        guard let loaded else { return item == nil ? "" : failure ?? "Reading…" }
        var parts: [String] = []
        if let imageView {
            parts.append("\(Int(imageView.imageSize.width)) × \(Int(imageView.imageSize.height))")
            if imageView.isDownsampled { parts.append("shown downsampled") }
            if imageView.framesDropped > 0 { parts.append("\(imageView.framesDropped) frames left out") }
        } else if contentView === pager, let document = pager.document {
            parts.append(
                mode == .hex || mode == .binary ? "\(mode.title), \(document.encoding.name)" : document.encoding.name)
            if let position = pager.position {
                parts.append(
                    mode == .hex || mode == .binary
                        ? "Offset \(Format.bytes(position.offset))" : "Line \(Format.bytes(Int64(position.line)))")
            }
            if let selection = pager.selection {
                parts.append("\(Format.bytes(selection.upperBound - selection.lowerBound)) bytes selected")
            }
            if pager.isIndexing { parts.append(String(format: "Indexing %.0f %%", pager.indexingProgress * 100)) }
        } else if contentView === pager, pager.isIndexing {
            // Nothing to draw yet: the rows of the start of the file are not known.
            parts.append(String(format: "Reading… %.0f %%", pager.indexingProgress * 100))
        } else {
            parts.append(mode.title)
        }
        if let error = pager.document?.readError {
            parts.append("Read error: \(error.localizedDescription)")
        }
        parts.append("\(Format.bytes(loaded.source.length)) bytes")
        return parts.joined(separator: "  ·  ")
    }

    func updateChrome() {
        statusLabel.stringValue = statusText
        percentButton.title = percentText
        percentButton.isHidden = percentText.isEmpty
        let several = fileCounter.count > 1
        for view in [previousButton, nextButton, counterLabel] as [NSView] { view.isHidden = !several }
        counterLabel.stringValue = "\(fileCounter.index + 1)/\(fileCounter.count)"
        progressBar.isHidden = activity == nil
        cancelButton.isHidden = activity == nil
        if let activity {
            progressBar.isIndeterminate = activity.progress == nil
            progressBar.doubleValue = activity.progress ?? 0
            if activity.progress == nil { progressBar.startAnimation(nil) }
        }
    }
}
