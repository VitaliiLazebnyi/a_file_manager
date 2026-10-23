import AFMKernel
import AppKit
import Quartz

/// Opening a file or a folder in the background, and the mode a file opens in.
extension ViewerPane {
    /// What the background needs to open and sample a file, taken on the main thread.
    private struct Opening {
        /// What is opened.
        let item: ViewerItem
        let fileSystems: FileSystemRegistry
        /// The extensions configured as multimedia, and those never shown as such.
        let additionalMedia: Set<String>
        let vetoed: Set<String>
        /// How a file whose reads are slow is kept once read (`slowFileBlocks`).
        let blocks: (size: Int, count: Int)

        /// Opens and samples the item; nil when it was no longer wanted before a file system answered.
        ///
        /// A file system that does not answer must not hold this thread: the work is asked of a
        /// kernel thread (at most 64 per file system), and this thread goes on once the file is no
        /// longer wanted, whatever the file system does.
        func run(cancellation: CancellationFlag) -> Result<Loaded, any Error>? {
            guard case .file(let url) = item.source, let provider = try? fileSystems.provider(for: url) else {
                return open(cancellation)
            }
            return BlockingCalls.answer(
                from: provider,
                to: "view " + url.absoluteString,
                sharing: false,
                cancellation: cancellation
            ) { flag in
                open(flag)
            }
        }

        /// Opens and samples the item. `flag` ends it: the pane's own, or, for a file system, the one
        /// `BlockingCalls` hands over once nobody waits for the answer.
        func open(_ flag: CancellationFlag) -> Result<Loaded, any Error> {
            Result { () -> Loaded in
                switch item.source {
                case .text(let text):
                    let data = Data(text.utf8)
                    return Loaded(
                        item: item,
                        source: DataByteSource(data),
                        sample: data.prefix(ViewerDetection.sampleSize),
                        guess: ViewerDetection.TextGuess(encoding: .utf8),
                        content: .other,
                        parallel: true
                    )

                case .file(let url):
                    return try openFile(url, flag)
                }
            }
        }

        /// Opens the file at `url` through its provider, kept in memory or on disk as its file system needs.
        private func openFile(_ url: URL, _ flag: CancellationFlag) throws -> Loaded {
            let provider = try fileSystems.provider(for: url)
            // What a plugin still holds back for this file (an archive written after a delay) is written
            // first.
            try fileSystems.flushPendingWrites(to: url, cancellation: flag)
            if provider.item(at: url, cancellation: flag)?.isDirectory == true {
                throw FileSystemError.notSupported("Viewing a folder")
            }
            let opened = try ProviderByteSource.open(url, fileSystems: fileSystems, cancellation: flag)
            let isLocal =
                opened is DataByteSource
                || (provider.volume(of: url, cancellation: flag)?.isLocal ?? false)
            // Where a read is slow (a server), a file that fits in the blocks is kept whole
            // once it has been read, and a bigger one on disk, so laying the text out again
            // does not fetch it again.
            let source =
                isLocal
                ? CachedByteSource(opened, policy: .standard)
                : CachedByteSource(
                    opened,
                    policy: CachedByteSource.Policy(
                        blockSize: blocks.size,
                        capacity: blocks.count,
                        wholeFileLimit: Int64(blocks.size) * Int64(blocks.count),
                        spillsToDisk: true,
                        diskLimit: CachedByteSource.Policy.standard.diskLimit
                    )
                )
            let sample = try source.read(at: 0, count: ViewerDetection.sampleSize, cancellation: flag)
            return Loaded(
                item: item,
                source: source,
                sample: sample,
                guess: ViewerDetection.guessText(sample, isWholeFile: Int64(sample.count) >= source.length),
                content: ViewerDetection.content(
                    name: url.lastPathComponent,
                    sample: sample,
                    additionalMedia: additionalMedia,
                    vetoed: vetoed
                ),
                parallel: isLocal
            )
        }
    }

    /// All the bytes of a file, for a mode that needs them at once; nil beyond `limit` or when they
    /// cannot be read.
    ///
    /// A file on the local disk is mapped, the others are read through `source`.
    nonisolated internal static func wholeData(
        of source: any ByteSource,
        at url: URL,
        limit: Int64,
        cancellation: CancellationFlag
    ) -> Data? {
        guard source.length <= limit else {
            return nil
        }
        if url.isFileURL {
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        return try? source.read(0..<source.length, cancellation: cancellation)
    }

    /// Shows a file or a text.
    ///
    /// Returns at once; the content appears when it has been read.
    internal func load(_ item: ViewerItem) {
        stopWork()
        self.item = item
        loaded = nil
        failure = nil
        folderSummary = nil
        strippedHTML = nil
        codePage = nil
        onTitleChange(item.title)
        let generation = loadGeneration
        let loadCancellation = cancellation
        let opening = Opening(
            item: item,
            fileSystems: kernel.fileSystems,
            additionalMedia: settings.additionalMediaTypes,
            vetoed: settings.noMediaTypes,
            blocks: slowFileBlocks
        )
        updateChrome()
        workQueue.async { [weak self] in
            // Moved on before this got a thread (the cursor ran over many files): nothing to read.
            guard !loadCancellation.isCancelled, let result = opening.run(cancellation: loadCancellation) else {
                return
            }
            DispatchQueue.main.async {
                // The file is let go of when the pane went or moved on meanwhile.
                guard let self, self.loadGeneration == generation, !loadCancellation.isCancelled else {
                    ViewerCleanup.close((try? result.get())?.source)
                    return
                }
                self.finishLoading(result)
            }
        }
    }

    /// Reads the file again (F2).
    internal func reload() {
        if let item { load(item) }
    }

    /// Stops whatever the pane is doing for the file it shows and lets go of the file.
    internal func stopWork() {
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
    internal func clear() {
        clear(message: "")
    }

    /// Shows `message` and nothing else.
    internal func clear(message: String) {
        stopWork()
        item = nil
        loaded = nil
        folderSummary = nil
        showMessage(message)
    }

    /// Shows what a folder holds instead of a file (spec 03 › Quick View: on a folder,
    /// information about its occupied space).
    ///
    /// The folder is counted in the background, on all cores; moving on to something else stops the
    /// counting.
    internal func showFolder(_ url: URL, name: String) {
        clear(message: "\(name)\n\nCounting…")
        let generation = loadGeneration
        let folderCancellation = cancellation
        let fileSystems = kernel.fileSystems
        workQueue.async { [weak self] in
            guard !folderCancellation.isCancelled, let provider = try? fileSystems.provider(for: url) else {
                return
            }
            // A tree on a server is a trip per folder: the quick view counts a part of it only.
            let isLocal = provider.volume(of: url, cancellation: folderCancellation)?.isLocal ?? true
            let summary = FolderSummary.measure(
                url,
                provider: provider,
                cancellation: folderCancellation,
                limit: isLocal ? nil : Self.remoteFolderEntryLimit
            )
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation, !folderCancellation.isCancelled else {
                    return
                }
                self.folderSummary = summary
                self.showMessage("\(name)\n\n\(summary.text)")
            }
        }
    }

    /// Shows a line of explanation in place of the content.
    internal func showMessage(_ text: String) {
        pager.clear()
        dropRichViews()
        setContent(RichViews.message(text), keyboardTo: nil)
        updateChrome()
    }

    /// Lets go of the views of the rich modes; the player stops.
    internal func dropRichViews() {
        mediaView?.stop()
        closePreview()
        (imageView, mediaView, pdfView, webView, richText) = (nil, nil, nil, nil, nil)
    }

    /// Lets go of the Quick Look view.
    ///
    /// One that is in a window has a window of its own until it is closed; closing one that is in
    /// no window (never was, or no longer is) ends the program, so it is closed only in a window,
    /// and before the pane leaves its window (`viewWillMove`).
    internal func closePreview() {
        if previewView?.window != nil { previewView?.close() }
        previewView = nil
    }

    /// The text mode a file opens in: as configured, else Binary for binary bytes, UTF-8 or Unicode for a text
    /// in them, plain text otherwise.
    internal func startupTextMode(for loaded: Loaded) -> ViewMode {
        switch settings.startupMode {
        case 2:
            return .binary

        case 3:
            return .hex

        case 0 where loaded.guess.isBinary:
            return .binary

        default:
            switch loaded.guess.encoding.kind {
            case .utf8:
                return .utf8

            case .utf16LE, .utf16BE:
                return .unicode

            default:
                return .text
            }
        }
    }

    /// Shows the file that was opened, or why it could not be.
    private func finishLoading(_ result: Result<Loaded, any Error>) {
        switch result {
        case .success(let loaded):
            self.loaded = loaded
            chooseStartupMode(for: loaded)
            present()

        case .failure(let error):
            failure = error.localizedDescription
            showMessage(error.localizedDescription)
        }
    }

    /// The mode a file opens in (spec 10 › Reference algorithm).
    private func chooseStartupMode(for loaded: Loaded) {
        let ext = loaded.item.url?.pathExtension.lowercased() ?? ""
        switch settings.startupFont {
        case 1:
            fontSlot = .ansi

        case 2:
            fontSlot = .ascii

        case 3:
            fontSlot = .variable

        default:
            fontSlot = loaded.guess.encoding == .dos ? .ascii : .ansi
        }
        mode = startupTextMode(for: loaded)
        guard !internalOnly, loaded.item.url != nil else {
            return
        }
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
}
