import AFMContracts
import AFMKernel
import AVKit
import AppKit
import PDFKit
import Quartz
import WebKit

/// Local copies of files that live on another file system, for the system frameworks that can
/// only play or preview a file on disk (spec 10 › Files that are not plain local files: such
/// files are copied to a temporary folder first). `localURL` blocks and is safe to call from
/// any thread.
///
/// Every copy has a folder of its own (two copies in flight never touch each other's file), is
/// known by where the file is together with its size and date (a file that changed is copied
/// again), and is kept for as long as a pane that asked for it shows it (`release`), then for a
/// little while in case it is shown again. `removeAll` (the plugin stopping) and the object going
/// away delete the lot; what a crash left behind is swept at the next launch.
///
/// What changes is guarded by `lock`; `directory` is immutable.
final class TemporaryCopies: @unchecked Sendable {
    private struct Copy {
        var folder: URL
        var file: URL
        var owners: Set<ObjectIdentifier>
        var lastUsed: Int
        var size: Int64
    }

    /// Why a copy was not made.
    enum Refusal: Error, Equatable {
        case cancelled
        case tooLarge(Int64)
        case noRoom
        case unreadable

        var isCancelled: Bool { self == .cancelled }

        var message: String {
            switch self {
            case .cancelled: return ""

            case .tooLarge(let size):
                return
                    "The file (\(Format.shortSize(size))) is too large to be copied from its file system for this mode (the limit is \(Format.shortSize(TemporaryCopies.sizeLimit))). "
                    + "Choose a text mode (1, 2 or 3)."

            case .noRoom: return "There is not enough free space on the disk to copy the file for this mode."
            case .unreadable: return "The file cannot be shown in this mode."
            }
        }
    }

    /// Copies nobody shows that are kept for the next time.
    static let idleLimit = 2
    /// ... but together no more than this many bytes.
    static let idleByteLimit: Int64 = 512 << 20
    /// The most that is copied for one file.
    static let sizeLimit: Int64 = 1 << 30
    /// What must stay free on the disk after a copy.
    static let freeSpaceMargin: Int64 = 256 << 20

    private let lock = NSLock()
    private var root: URL?
    private var copies: [String: Copy] = [:]
    private var clock = 0
    /// How often `removeAll` ran: a copy that was begun before one is not registered.
    private var epoch = 0
    /// How often each owner released its copies: a copy begun before is not kept for that owner.
    private var releases: [ObjectIdentifier: Int] = [:]
    private let directory: URL

    init(directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
        _ = Self.sweepOnce
    }

    /// The file itself when it is on the local disk, else a copy of it read through its
    /// provider, kept for `owner` until it is released. Nil when it cannot be read or
    /// `cancellation` was set.
    func localURL(
        for url: URL, fileSystems: FileSystemRegistry, owner: ObjectIdentifier = ObjectIdentifier(TemporaryCopies.self),
        cancellation: CancellationFlag
    ) -> URL? {
        try? localCopy(for: url, fileSystems: fileSystems, owner: owner, cancellation: cancellation).get()
    }

    /// `localURL`, with the reason when there is none.
    func localCopy(
        for url: URL, fileSystems: FileSystemRegistry, owner: ObjectIdentifier = ObjectIdentifier(TemporaryCopies.self),
        cancellation: CancellationFlag
    ) -> Result<URL, Refusal> {
        if url.isFileURL { return .success(url) }
        guard let provider = try? fileSystems.provider(for: url) else { return .failure(.unreadable) }
        let item = provider.item(at: url, cancellation: cancellation)
        let key = "\(url.locationKey)|\(item?.size ?? -1)|\(item?.modified.timeIntervalSince1970 ?? 0)"
        if let known = use(key, by: owner) { return .success(known) }
        if cancellation.isCancelled { return .failure(.cancelled) }
        // A file of a server is not put on the disk without asking whether it fits.
        if let size = item?.size, size > Self.sizeLimit { return .failure(.tooLarge(size)) }
        let started = begin(owner)
        // Changes that a plugin still holds back for this file (an archive written after a delay) are written first.
        do { try fileSystems.flushPendingWrites(to: url, cancellation: cancellation) } catch {
            return .failure(cancellation.isCancelled ? .cancelled : .unreadable)
        }
        guard let reader = try? provider.read(url, cancellation: cancellation) else {
            return .failure(cancellation.isCancelled ? .cancelled : .unreadable)
        }
        defer { reader.close() }
        guard let folder = newFolder() else { return .failure(.unreadable) }
        if let size = item?.size, let free = freeSpace(), free - size < Self.freeSpaceMargin {
            try? FileManager.default.removeItem(at: folder)
            return .failure(.noRoom)
        }
        let name = Self.safeName(url.lastPathComponent)
        let target = folder.appendingPathComponent(name, isDirectory: false)
        // The name is one component of the folder just made, and the file is new (O_EXCL).
        guard target.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else {
            try? FileManager.default.removeItem(at: folder)
            return .failure(.unreadable)
        }
        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: folder)
            return .failure(.unreadable)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        // A read that waits for a server is ended by the flag; what it threw is no end of the file.
        var written: Int64 = 0
        var refusal: Refusal?
        let copied = cancellation.whileReading(reader) { () -> Bool in
            do {
                while let block = try autoreleasepool(invoking: { try reader.read(upToCount: 1 << 20) }), !block.isEmpty
                {
                    guard !cancellation.isCancelled else { return false }
                    written += Int64(block.count)
                    // A size that the listing did not tell is limited as it is read.
                    guard written <= Self.sizeLimit else {
                        refusal = .tooLarge(written)
                        return false
                    }
                    try handle.write(contentsOf: block)
                }
                return !cancellation.isCancelled
            } catch {
                return false
            }
        }
        guard copied else {
            try? FileManager.default.removeItem(at: folder)
            return .failure(refusal ?? (cancellation.isCancelled ? .cancelled : .unreadable))
        }
        // A file that came from a server keeps saying so; the copy is a plain local file, so the mark
        // can go on while the handle is still open (a mark that cannot be put on does not stop the viewing).
        if let mark = provider.quarantine(of: url), let local = try? fileSystems.provider(for: target) {
            try? local.setQuarantine(mark, of: target)
        }
        lock.lock()
        // `removeAll` ran while the file was copied: the folder it made is gone, and so is this.
        guard started.epoch == epoch else {
            lock.unlock()
            try? FileManager.default.removeItem(at: folder)
            return .failure(.cancelled)
        }
        // Another thread may have copied the same file meanwhile: its copy stays.
        if copies[key] != nil {
            lock.unlock()
            try? FileManager.default.removeItem(at: folder)
            return use(key, by: owner).map { .success($0) } ?? .failure(.unreadable)
        }
        clock += 1
        // The owner let go of its copies while this one was made: it is kept like the idle ones.
        let owned = (releases[owner] ?? 0) == started.release
        copies[key] = Copy(folder: folder, file: target, owners: owned ? [owner] : [], lastUsed: clock, size: written)
        lock.unlock()
        evict()
        return .success(target)
    }

    /// A file name for a copy: one path component, whatever the name of the file was (it may
    /// be anything a server sent, decoded: `..`, `a/b`, a very long name).
    static func safeName(_ name: String) -> String {
        var cleaned = String(
            String.UnicodeScalarView(
                name.unicodeScalars.map { scalar in
                    scalar == "/" || scalar == ":" || scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F
                        ? "_" : scalar
                }))
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) { return "file" }
        // A name is at most 255 bytes: keep the end, which holds the extension that picks the player.
        while cleaned.utf8.count > 200 { cleaned.remove(at: cleaned.index(after: cleaned.startIndex)) }
        return cleaned.first == "." ? "_" + cleaned : cleaned
    }

    /// The bytes free for a program on the disk of the temporary folder.
    private func freeSpace() -> Int64? {
        var info = statfs()
        guard statfs(directory.path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    private func begin(_ owner: ObjectIdentifier) -> (epoch: Int, release: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (epoch, releases[owner] ?? 0)
    }

    private func use(_ key: String, by owner: ObjectIdentifier) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard var copy = copies[key] else { return nil }
        clock += 1
        copy.owners.insert(owner)
        copy.lastUsed = clock
        copies[key] = copy
        return copy.file
    }

    /// The pane `owner` shows something else: its copies are kept only while the idle ones are
    /// few enough.
    func release(owner: ObjectIdentifier) {
        lock.lock()
        releases[owner, default: 0] += 1
        for key in copies.keys where copies[key]?.owners.contains(owner) == true { copies[key]?.owners.remove(owner) }
        lock.unlock()
        evict()
    }

    /// Deletes the idle copies beyond the limits, the least recently used first. The files are
    /// deleted on a background queue: this is called on the main thread.
    private func evict() {
        lock.lock()
        let idle = copies.filter { $0.value.owners.isEmpty }.sorted { $0.value.lastUsed > $1.value.lastUsed }
        var doomed: [URL] = []
        var kept = 0
        var keptBytes: Int64 = 0
        for (key, copy) in idle {
            if kept < Self.idleLimit, keptBytes + copy.size <= Self.idleByteLimit {
                kept += 1
                keptBytes += copy.size
            } else {
                copies[key] = nil
                doomed.append(copy.folder)
            }
        }
        lock.unlock()
        guard !doomed.isEmpty else { return }
        group.enter()
        ViewerCleanup.async { [group, doomed] in
            for folder in doomed { try? FileManager.default.removeItem(at: folder) }
            group.leave()
        }
    }

    /// What is being deleted in the background.
    private let group = DispatchGroup()

    /// Returns once the copies that were let go of have been deleted (for tests).
    func waitForCleanup() {
        group.wait()
    }

    /// Deletes every copy and the folder that held them: in the background, but `removeAll` waits
    /// a moment for it (the program is about to end when the plugin stops) and never longer.
    ///
    /// With `waiting` off it does not wait at all; `done` is called, on whatever thread, once the
    /// deletion has been carried out (at once when there was nothing to delete).
    func removeAll(waiting: Bool = true, then done: (@Sendable () -> Void)? = nil) {
        lock.lock()
        let folder = root
        root = nil
        copies = [:]
        epoch += 1
        lock.unlock()
        guard let folder else {
            done?()
            return
        }
        group.enter()
        ViewerCleanup.async { [group] in
            try? FileManager.default.removeItem(at: folder)
            group.leave()
            done?()
        }
        if waiting { _ = group.wait(timeout: .now() + 2) }
    }

    /// A new, empty folder of its own for one copy.
    private func newFolder() -> URL? {
        // The disk is asked outside the lock, which the main thread takes as well.
        lock.lock()
        var base = root
        lock.unlock()
        if base == nil {
            let created = directory.appendingPathComponent(
                "\(Self.prefix)p\(getpid())-\(UUID().uuidString)", isDirectory: true)
            guard
                (try? FileManager.default.createDirectory(
                    at: created, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
            else { return nil }
            lock.lock()
            if root == nil { root = created }
            base = root
            lock.unlock()
            if base != created { try? FileManager.default.removeItem(at: created) }
        }
        guard let base else { return nil }
        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return
            (try? FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
            ? folder : nil
    }

    deinit { removeAll() }

    // MARK: Leftovers

    private static let prefix = "afm-viewer-"

    /// Once per launch, in the background: removes the folders of processes that are gone (a crash
    /// does not run `deinit`), and those of earlier versions that are over a day old.
    static let sweepOnce: Void = {
        BlockingCalls.run { sweep(in: FileManager.default.temporaryDirectory) }
    }()

    static func sweep(in directory: URL, now: Date = Date()) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            let rest = name.dropFirst(prefix.count)
            if rest.hasPrefix("p"), let pid = Int32(rest.dropFirst().prefix { $0 != "-" }) {
                if pid != getpid(), kill(pid, 0) != 0, errno == ESRCH { try? manager.removeItem(at: folder) }
            } else if let modified = (try? manager.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date,
                now.timeIntervalSince(modified) > 86_400
            {
                try? manager.removeItem(at: folder)
            }
        }
    }
}

/// The media player mode (spec 10 › Media player mode), on AVKit. Main thread only.
final class MediaView: NSView {
    private let playerView = AVPlayerView()
    private let player = AVPlayer()
    /// Set on the main thread, read in `deinit`.
    nonisolated(unsafe) private var endObserver: any NSObjectProtocol?
    /// Called when the track has played to its end (a playlist then moves on).
    var onEnd: () -> Void = {}
    /// Called with "track – artist" when the file's tags name them.
    var onTitle: (String) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.autoresizingMask = [.width, .height]
        playerView.frame = bounds
        addSubview(playerView)
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(_ url: URL, volume: Float) {
        let item = AVPlayerItem(url: url)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue.
            MainActor.assumeIsolated { self?.onEnd() }
        }
        player.replaceCurrentItem(with: item)
        player.volume = volume
        player.play()
        let asset = item.asset
        // Reading the tags may take a moment on a slow disk; it is not done on the main thread.
        Task { [weak self] in
            guard let metadata = try? await asset.load(.commonMetadata) else { return }
            var values: [AVMetadataKey: String] = [:]
            for item in metadata {
                guard let key = item.commonKey, let value = try? await item.load(.stringValue) else { continue }
                values[key] = value
            }
            guard let title = values[.commonKeyTitle] else { return }
            let text = values[.commonKeyArtist].map { "\(title) – \($0)" } ?? title
            await MainActor.run { self?.onTitle(text) }
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    var volume: Float { player.volume }

    func togglePlaying() {
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    func toggleMute() { player.isMuted.toggle() }

    func changeVolume(by delta: Float) {
        player.volume = min(1, max(0, player.volume + delta))
    }

    func seek(by seconds: Double) {
        let target = CMTimeAdd(player.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: CMTimeMaximum(target, .zero), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// One video frame, or a tenth of a second of audio (key E).
    func step() {
        player.pause()
        guard let item = player.currentItem else { return }
        if item.canStepForward { item.step(byCount: 1) } else { seek(by: 0.1) }
    }

    /// Fit the video to the window, or fill the window with it (key F).
    func toggleFit() {
        playerView.videoGravity = playerView.videoGravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
    }
}

/// HTML shown as a page: scripts do not run and nothing is loaded from elsewhere, so a file is
/// safe to look at. The page is shown once, from the string; every navigation after that is
/// refused (a `<meta http-equiv="refresh">` and a script-less redirect are navigations too, and
/// would load a page of the web into the viewer), and a link that was clicked is handed to
/// `onLink`. Main thread only.
final class WebContentView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    var onLink: (URL) -> Void = { _ in }
    /// Whether the load of the page itself is still to come.
    private var expectsPage = false
    /// Forbids every load but inline styles and images that are part of the page itself.
    static let policy =
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:\">"

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        super.init(frame: frame)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

    func show(html: String) {
        expectsPage = true
        webView.loadHTMLString(Self.policy + html, baseURL: nil)
    }

    /// What a navigation is allowed to do: the first one (the page, from a string), a jump to a
    /// place in the page (`#name`), and nothing else.
    enum Decision: Equatable {
        case allow, cancel, followLink
    }

    nonisolated static func decide(isMainFrame: Bool, isLinkClick: Bool, url: URL?, expectsPage: Bool) -> Decision {
        let isBlank =
            url.map {
                $0.scheme == "about"
                    && ($0.absoluteString == "about:blank" || $0.absoluteString.hasPrefix("about:blank#"))
            } ?? false
        if isLinkClick {
            // A jump inside the page stays in the page.
            if isMainFrame, isBlank, url?.fragment != nil { return .allow }
            return url == nil ? .cancel : .followLink
        }
        // The page itself, the one time (WebKit names it `about:blank`, or has no name for it when
        // it comes from a string): anything later (a refresh, a redirect, a frame) is refused.
        let isString = url == nil || url?.scheme == "about" || url?.scheme == "applewebdata"
        if expectsPage, isMainFrame, isString { return .allow }
        return .cancel
    }

    func webView(
        _: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let decision = Self.decide(
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
            isLinkClick: navigationAction.navigationType == .linkActivated,
            url: navigationAction.request.url, expectsPage: expectsPage)
        switch decision {
        case .allow:
            if navigationAction.navigationType != .linkActivated { expectsPage = false }
            decisionHandler(.allow)

        case .followLink:
            if let url = navigationAction.request.url { onLink(url) }
            decisionHandler(.cancel)

        case .cancel:
            decisionHandler(.cancel)
        }
    }

    func printOperation(with info: NSPrintInfo) -> NSPrintOperation { webView.printOperation(with: info) }
}

/// What a link in a file that is viewed may do. A file is untrusted: a click on a link in it
/// opens a web page or a mail in the program for that, and the viewer follows only links to
/// files beside the one shown. Everything else (`file:`, `smb:`, `ftp:`, `sftp:`, the URL
/// schemes of other programs) does nothing.
enum LinkPolicy {
    static func opensInBrowser(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "mailto" { return true }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    /// The file a link names when the viewer may load it: a relative link, resolved against
    /// `base`, that lies in the folder of `base` or below it, on the same file system (the same
    /// scheme, host and port). Nil otherwise.
    static func target(of link: URL, relativeTo base: URL) -> URL? {
        let text = link.relativeString.replacingOccurrences(of: "about:blank", with: "")
        guard !text.isEmpty, let resolved = URL(string: text, relativeTo: base) else { return nil }
        // A link with a scheme of its own (an absolute one) is not relative.
        if let own = URL(string: text)?.scheme, own.lowercased() != base.scheme?.lowercased() { return nil }
        guard var parts = URLComponents(url: resolved.absoluteURL, resolvingAgainstBaseURL: true) else { return nil }
        parts.query = nil
        parts.fragment = nil
        guard let target = parts.url, target.scheme?.lowercased() == base.scheme?.lowercased(),
            (target.host ?? "").lowercased() == (base.host ?? "").lowercased(), target.port == base.port,
            target.user == base.user
        else { return nil }
        // No component holds a separator or goes up: `..%2F..%2Fx` is one component after decoding.
        let components = Array(target.pathComponents.drop { $0 == "/" })
        guard !components.contains(where: { $0 == ".." || $0 == "." || $0.contains("/") || $0.contains("\0") }) else {
            return nil
        }
        let folder = base.deletingLastPathComponent()
        guard target.isInside(folder) else { return nil }
        return target
    }
}

/// The delegate of the views that show RTF and PDF: a click on a link opens a web page or a
/// mail and nothing else (the framework would open any URL, a file or a share included).
@MainActor
final class LinkGate: NSObject, NSTextViewDelegate, @preconcurrency PDFViewDelegate {
    private static var key = 0

    /// What is done with a link that may be opened (tests put their own in).
    private let opener: (URL) -> Void

    init(opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.opener = opener
    }

    /// Keeps the gate alive for as long as `view` is (the views hold their delegates weakly).
    func attach(to view: NSObject) {
        objc_setAssociatedObject(view, &Self.key, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func open(_ link: Any) {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) } ?? (link as? NSURL) as URL?
        if let url, LinkPolicy.opensInBrowser(url) { opener(url) }
    }

    func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
        open(link)
        // Handled: the text view does not open it again.
        return true
    }

    func pdfViewWillClick(onLink _: PDFView, with url: URL) {
        open(url)
    }
}

/// Factories for the views that need no class of their own.
@MainActor
enum RichViews {
    /// A read-only text view in a scroll view: RTF (spec 10 › RTF) and printing.
    static func textView(_ text: NSAttributedString) -> (scroll: NSScrollView, text: NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as? NSTextView ?? NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.textStorage?.setAttributedString(text)
        view.usesFindBar = true
        let gate = LinkGate()
        view.delegate = gate
        gate.attach(to: view)
        return (scroll, view)
    }

    static func pdfView(_ document: PDFDocument) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        let gate = LinkGate()
        view.delegate = gate
        gate.attach(to: view)
        return view
    }

    /// The Mac's counterpart of Lister plugins and of the Explorer preview: whatever Quick
    /// Look can show (spec 10 › Explorer Preview).
    static func quickLookView(_ url: URL) -> QLPreviewView? {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else { return nil }
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    /// A line of explanation in place of a file that cannot be shown.
    static func message(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40)
        ])
        return view
    }
}
