import AFMKernel
import AppKit
import PDFKit

/// Showing the loaded file in the current mode: as rows of text, or in the view of a rich mode.
extension ViewerPane {
    /// What the background made ready for a rich mode.
    private enum Ready {
        case image(DecodedImage)
        case pdf(PDFDocument)
        case html(String)
        case rtf(NSAttributedString)
        case local(URL)
        case failed(String)
        /// Too big to lay out on the main thread: the text modes show it.
        case asText
    }

    /// What the background needs to make a file ready for a rich mode, taken on the main thread.
    private struct RichRequest {
        let url: URL
        let source: any ByteSource
        /// How it is shown: as an image, a PDF, a page, a formatted text, or played or previewed from a file.
        let content: ViewerDetection.Content
        /// The cancellation of the `present` it is for.
        let cancellation: CancellationFlag
        let minimumDelay: Double
        let htmlEncoding: ViewerEncoding
        let copies: TemporaryCopies
        let fileSystems: FileSystemRegistry
        /// The pane the local copy is kept for.
        let owner: ObjectIdentifier

        /// Reads, decodes or copies the file; `firstFrame` receives an animation's first frame early.
        ///
        /// A file on the local disk is read by the framework that shows it, as far as it needs;
        /// only other file systems are read whole into memory here.
        func prepare(firstFrame: @escaping (DecodedImage) -> Void) -> Ready {
            let made: Ready?
            switch content {
            case .image:
                made = image(firstFrame: firstFrame)

            case .pdf:
                let document = url.isFileURL ? PDFDocument(url: url) : whole().flatMap(PDFDocument.init(data:))
                made = document.map(Ready.pdf)

            case .html:
                made = html()

            case .rtf:
                made = rtf()

            case .media, .other:
                made = localCopy()
            }
            return made ?? .failed("The file cannot be shown in this mode.")
        }

        /// The decoded image; nil when it cannot be decoded.
        private func image(firstFrame: @escaping (DecodedImage) -> Void) -> Ready? {
            let decoder = ImageDecoder(
                minimumDelay: minimumDelay,
                cancellation: cancellation,
                firstFrame: firstFrame
            )
            let image = url.isFileURL ? decoder.decode(contentsOf: url) : whole().flatMap { decoder.decode($0) }
            return image.map(Ready.image)
        }

        /// The page's text, or `.asText` for a page too big to lay out; nil when it cannot be read.
        private func html() -> Ready? {
            guard source.length <= ViewerPane.htmlPageLimit else {
                return .asText
            }
            return whole().map { .html(htmlEncoding.string(from: $0)) }
        }

        /// The formatted text, or `.asText` for one too big to lay out; nil when it cannot be read.
        private func rtf() -> Ready? {
            guard source.length <= ViewerPane.rtfLimit else {
                return .asText
            }
            return whole().flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }.map(Ready.rtf)
        }

        /// A local copy to play or preview; nil when making it was cancelled.
        private func localCopy() -> Ready? {
            switch copies.localCopy(for: url, fileSystems: fileSystems, owner: owner, cancellation: cancellation) {
            case .success(let local):
                return .local(local)

            case .failure(let refusal):
                return refusal.isCancelled ? nil : .failed(refusal.message)
            }
        }

        /// All of the file, for the frameworks that are given its bytes.
        private func whole() -> Data? {
            ViewerPane.wholeData(of: source, at: url, limit: ViewerPane.wholeFileLimit, cancellation: cancellation)
        }
    }

    /// The text of an HTML file without its tags, and its links; nil when it was stopped.
    nonisolated private static func stripTags(
        of loaded: Loaded,
        encoding: ViewerEncoding,
        linkBraces: Bool,
        cancellation: CancellationFlag
    ) throws -> (links: [String], source: any ByteSource)? {
        let range = Int64(loaded.guess.bomLength)..<loaded.source.length
        let data = try loaded.source.read(range, cancellation: cancellation)
        if Int64(data.count) < range.upperBound - range.lowerBound { throw ViewerError.fileChanged }
        guard !cancellation.isCancelled,
            let result = HTMLText.plainText(
                units: encoding.units(from: data),
                linkBraces: linkBraces,
                cancellation: cancellation
            )
        else { return nil }
        return (result.links, DataByteSource(Data(result.text.utf8)))
    }

    /// Switches the display mode (Options › 1…8).
    internal func setMode(_ newMode: ViewMode) {
        guard loaded != nil else {
            return
        }
        // 4 again goes on to the next way of showing the file (the specification cycles
        // through the plugins; here that is Quick Look).
        mode = newMode == .media && mode == .media && settings.usesQuickLook && !internalOnly ? .preview : newMode
        present()
    }

    /// Shows the loaded file in the current mode, from the start of a text.
    internal func present() {
        present(keeping: nil)
    }

    /// Shows the loaded file in the current mode; `offset` keeps that byte of the text at the top.
    internal func present(keeping offset: Int64?) {
        guard let loaded else {
            return
        }
        presentGeneration += 1
        presentCancellation.cancel()
        presentCancellation = CancellationFlag()
        if mode == .html, strippedHTML == nil {
            stripHTML(loaded)
            return
        }
        if mode.isTextual {
            presentText(loaded, keeping: offset)
        } else {
            pager.clear()
            presentRich(loaded)
        }
        updateChrome()
    }

    /// The text of an HTML file shown as text is cut again from its bytes the next time (after
    /// another encoding was chosen).
    internal func redecodeHTML() {
        if mode == .html { strippedHTML = nil }
    }

    /// A link in an HTML page, after a click on it: a page elsewhere opens in the browser, a
    /// file below the folder of this one in the viewer (spec 10 › HTML text).
    ///
    /// Nothing else is followed: a page cannot make the viewer open another server, another folder,
    /// or a local file it does not sit beside.
    internal func followLink(_ link: URL) {
        if LinkPolicy.opensInBrowser(link) {
            links.open(link)
        } else if let base = item?.url, let target = LinkPolicy.target(of: link, relativeTo: base) {
            load(ViewerItem(source: .file(target), title: kernel.fileSystems.displayPath(target)))
        }
    }

    /// Shows the text of the loaded file in the pager, laid out for the current mode.
    private func presentText(_ loaded: Loaded, keeping offset: Int64?) {
        dropRichViews()
        pager.font = currentFont
        pager.showsCaret = settings.caret
        pager.searchGoBack = settings.searchGoBack
        setContent(pager, keyboardTo: pager)
        // The width decides where a text wrapped at the window's edge is cut.
        if window != nil { layoutSubtreeIfNeeded() }
        let source = (mode == .html ? strippedHTML?.source : nil) ?? loaded.source
        let hasMark = mode != .html && ViewerDetection.byteOrderMark(loaded.sample)?.encoding == encoding
        // The text laid out before is given: what is the same in both is not read again.
        let document = TextDocument(
            source: source,
            encoding: encoding,
            bomLength: hasMark ? loaded.guess.bomLength : 0,
            layout: layout,
            reusing: pager.document
        )
        pager.show(
            document,
            at: offset ?? 0,
            select: nil,
            keepingSelection: offset != nil && pager.document?.source === source,
            parallel: loaded.parallel
        )
    }

    /// Reads an HTML file whole, removes its tags off the main thread and shows the text.
    ///
    /// A file beyond `htmlTextLimit` is shown as plain text instead.
    private func stripHTML(_ loaded: Loaded) {
        let generation = loadGeneration
        let token = presentGeneration
        let cancel = presentCancellation
        let braces = settings.linkBraces
        let charset =
            ViewerDetection.htmlCharset(loaded.sample)
            ?? (loaded.guess.encoding.isUnicode ? loaded.guess.encoding : codePage ?? fontSlot.encoding)
        guard loaded.source.length <= Self.htmlTextLimit else {
            mode = startupTextMode(for: loaded)
            present()
            return
        }
        workQueue.async { [weak self] in
            let outcome: Result<(links: [String], source: any ByteSource), any Error>
            do {
                // Stopped while the tags were removed: nothing is shown.
                guard
                    let stripped = try Self.stripTags(
                        of: loaded,
                        encoding: charset,
                        linkBraces: braces,
                        cancellation: cancel
                    )
                else { return }
                outcome = .success(stripped)
            } catch {
                guard !cancel.isCancelled else {
                    return
                }
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                // The mode may have been changed while the tags were removed: then this is not wanted.
                guard let self, self.loadGeneration == generation, self.presentGeneration == token, self.mode == .html
                else { return }
                switch outcome {
                case .success(let stripped):
                    self.strippedHTML = stripped
                    self.present()

                case .failure(let error):
                    self.failure = error.localizedDescription
                    self.showMessage(error.localizedDescription)
                }
            }
        }
    }

    /// Image, PDF, media, HTML page, RTF or Quick Look: read or copied in the background,
    /// shown when ready.
    private func presentRich(_ loaded: Loaded) {
        dropRichViews()
        guard let url = loaded.item.url else {
            showMessage("A text that is not a file can only be shown as text.")
            return
        }
        setContent(RichViews.message("Loading…"), keyboardTo: nil)
        let generation = loadGeneration
        let loadCancellation = cancellation
        let token = presentGeneration
        let presentCancel = presentCancellation
        let request = RichRequest(
            url: url,
            source: loaded.source,
            content: mode == .preview ? .other : loaded.content,
            cancellation: presentCancel,
            minimumDelay: settings.gifMinimumDelay,
            htmlEncoding: ViewerDetection.htmlCharset(loaded.sample) ?? loaded.guess.encoding,
            copies: temporaryCopies,
            fileSystems: kernel.fileSystems,
            owner: ObjectIdentifier(self)
        )
        // Whether what a job brings back is still wanted.
        let isCurrent: @MainActor @Sendable (ViewerPane) -> Bool = { pane in
            pane.loadGeneration == generation && pane.presentGeneration == token && !loadCancellation.isCancelled
                && !presentCancel.isCancelled && !pane.mode.isTextual
        }
        workQueue.async { [weak self] in
            // An animation shows its first frame while the others are still being decoded.
            let ready = request.prepare { first in
                DispatchQueue.main.async {
                    guard let self, isCurrent(self), self.imageView == nil else {
                        return
                    }
                    self.showImage(first)
                }
            }
            // Made on this thread, which does not touch it again.
            let made = Handover(ready)
            DispatchQueue.main.async {
                guard let self, isCurrent(self) else {
                    return
                }
                self.show(made.value, as: request.content, of: loaded)
            }
        }
    }

    /// Puts what the background made ready into the content area.
    private func show(_ ready: Ready, as content: ViewerDetection.Content, of loaded: Loaded) {
        switch ready {
        case .image(let image):
            if let view = imageView {
                view.replaceFrames(with: image)
                updateChrome()
            } else {
                showImage(image)
            }
            return

        case .pdf(let document):
            let view = RichViews.pdfView(document)
            pdfView = view
            setContent(view, keyboardTo: nil)

        case .html(let html):
            let view = WebContentView(frame: contentHost.bounds)
            view.onLink = { [weak self] link in self?.followLink(link) }
            webView = view
            setContent(view, keyboardTo: nil)
            view.show(html: html)

        case .rtf(let text):
            let views = RichViews.textView(text)
            richText = views.text
            setContent(views.scroll, keyboardTo: nil)

        case .local(let local):
            showLocal(local, asMedia: content == .media)

        case .failed(let reason):
            showMessage(reason)

        case .asText:
            mode = startupTextMode(for: loaded)
            present()
            return
        }
        updateChrome()
    }

    /// Plays a local file (or a copy) in the media view, or previews it with Quick Look.
    private func showLocal(_ local: URL, asMedia: Bool) {
        if asMedia {
            let view = MediaView(frame: contentHost.bounds, playback: mediaPlayback())
            view.onEnd = { [weak self] in self?.onStep(1) }
            view.onTitle = { [weak self] title in self?.onTitleChange(title) }
            mediaView = view
            setContent(view, keyboardTo: nil)
            view.play(local, volume: settings.playerVolume)
        } else if settings.usesQuickLook, !internalOnly, let view = RichViews.quickLookView(local) {
            previewView = view
            setContent(view, keyboardTo: nil)
        } else {
            showMessage("This is not an image or a multimedia file. Choose a text mode (1, 2 or 3).")
        }
    }

    /// Puts an image (or the first frame of an animation) on the screen.
    private func showImage(_ image: DecodedImage) {
        let view = ImageCanvasView(frame: contentHost.bounds)
        view.fit = settings.imageFit
        view.centered = settings.centersImages
        view.onZoomChange = { [weak self] in self?.updateChrome() }
        imageView = view
        setContent(view, keyboardTo: nil)
        view.show(image)
        updateChrome()
    }
}
