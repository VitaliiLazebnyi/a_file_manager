import AFMContracts
import AFMKernel
import AppKit

/// The clipboard and the context menu (spec 10 › Selection and clipboard, Context menu rules).
extension ViewerPane {
    /// The most that is copied to the clipboard at once (the string goes to the pasteboard on
    /// the main thread; hex is half of this).
    internal static let copyLimit: Int64 = 16 << 20

    /// The link in `text` around UTF-16 index `index`: the word there, when it is a link.
    internal static func link(in text: String, at index: Int) -> URL? {
        let units = Array(text.utf16)
        var lower = min(index, units.count)
        var upper = lower
        while lower > 0, units[lower - 1] != 0x20 { lower -= 1 }
        while upper < units.count, units[upper] != 0x20 { upper += 1 }
        return HTMLText.url(from: String(decoding: units[lower..<upper], as: UTF16.self))
    }

    /// Copies the selection as text or as hexadecimal values; see `copySelection(asHex:completion:)`.
    internal func copySelection(asHex: Bool) {
        copySelection(asHex: asHex) {
            // Nobody waits for the clipboard.
        }
    }

    /// Copies the selection as text or as hexadecimal values (spec 10 › Selection and
    /// clipboard); `completion` runs on the main thread once it is on the clipboard.
    ///
    /// The bytes are read in the background.
    internal func copySelection(asHex: Bool, completion: @escaping @MainActor @Sendable () -> Void) {
        guard let document = pager.document, let selection = pager.selection else {
            return
        }
        // Hex is three characters a byte; the string is made on the main thread for the clipboard.
        let limit = asHex ? Self.copyLimit / 2 : Self.copyLimit
        guard selection.upperBound - selection.lowerBound <= limit else {
            kernel.interaction.inform(
                "The selection is too large for the clipboard (more than \(Format.shortSize(limit)))."
            )
            return
        }
        // Carried through the background and used on the main thread only.
        let pasteboard = Handover(pasteboard)
        let cancellation = cancellation
        workQueue.async {
            let text =
                asHex
                ? (try? document.source.read(selection, cancellation: cancellation)).map(HexFormat.hexString)
                : try? document.text(in: selection, cancellation: cancellation)
            DispatchQueue.main.async {
                if let text {
                    pasteboard.value.clearContents()
                    pasteboard.value.setString(text, forType: .string)
                }
                completion()
            }
        }
    }

    /// The context menu (spec 10 › Context menu rules): with a selection, the copy commands
    /// and what can be done with a link; without one, only on a link.
    internal func makeContextMenu() -> NSMenu? {
        guard showsText, let window else {
            return nil
        }
        var link: URL?
        if pager.selection == nil, let hit = pager.text(at: window.mouseLocationOutsideOfEventStream) {
            link = Self.link(in: hit.text, at: hit.index)
            guard link != nil else {
                return nil
            }
        }
        var entries: [ViewerAction?] = pager.selection == nil ? [] : selectionEntries()
        if let link {
            let pasteboard = pasteboard
            entries += [
                ViewerAction(title: "Copy URL") {
                    pasteboard.clearContents()
                    pasteboard.setString(link.absoluteString, forType: .string)
                },
                ViewerAction(title: "Open in the default browser") { [weak self] in self?.links.open(link) }
            ]
        }
        if !htmlLinks.isEmpty {
            let pasteboard = pasteboard
            let links = htmlLinks
            entries.append(
                ViewerAction(title: "Copy all URLs") {
                    pasteboard.clearContents()
                    pasteboard.setString(links.joined(separator: "\n"), forType: .string)
                }
            )
        }
        let menu = NSMenu()
        fill(menu, with: entries)
        return menu
    }

    /// The entries of the context menu for a selection: copy it, search the web for it, open it as a link.
    private func selectionEntries() -> [ViewerAction?] {
        [
            ViewerAction(title: "Copy as text") { [weak self] in self?.copySelection(asHex: false) },
            ViewerAction(title: "Copy as hex") { [weak self] in self?.copySelection(asHex: true) },
            ViewerAction(title: "Search the web for the selection") { [weak self] in
                self?
                    .withSelectedText { text in
                        var components = URLComponents(string: "https://www.google.com/search")
                        components?.queryItems = [URLQueryItem(name: "q", value: text)]
                        if let url = components?.url { self?.links.open(url) }
                    }
            },
            ViewerAction(title: "Open the selection as a link in the browser") { [weak self] in
                self?
                    .withSelectedText { text in
                        if let url = HTMLText.url(from: text) { self?.links.open(url) }
                    }
            }
        ]
    }

    private func withSelectedText(_ action: @escaping @MainActor @Sendable (String) -> Void) {
        guard let document = pager.document, let selection = pager.selection, selection.count <= 4_096 else {
            return
        }
        workQueue.async {
            guard let text = try? document.text(in: selection, cancellation: nil) else {
                return
            }
            DispatchQueue.main.async { action(text) }
        }
    }
}
