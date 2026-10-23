import AFMKernel
import AppKit

/// Puts texts on the clipboard; the latest request wins.
///
/// Main thread only (`NSPasteboard` is not safe to use from another thread); a long text is
/// made on a thread of the kernel's own and handed to the pasteboard here.
@MainActor
internal final class TextClipboard {
    private let pasteboard: NSPasteboard
    /// Counts the texts and files asked for, so that a slow list does not overwrite a later one.
    private var request = 0

    /// Writes to `pasteboard`.
    internal init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// Overtakes whatever list of names is still being put together: it is dropped when it
    /// arrives, so it cannot land on top of what goes to the clipboard now.
    internal func overtake() {
        request += 1
    }

    /// Puts a text on the clipboard.
    ///
    /// Whatever list of names is still being put together for an earlier command is overtaken by
    /// this: it must not replace the text later.
    internal func put(_ text: String) {
        overtake()
        write(text)
    }

    /// Puts the text `make` returns on the clipboard.
    ///
    /// For a few items (`count` up to `ClipboardPlugin.listedAtOnce`) at once; for a very large
    /// selection the text is put together on a background queue (it is megabytes of paths) and
    /// only handed to the pasteboard here. The latest request wins: a text that arrives after
    /// something newer went to the clipboard (another text, or files) is dropped.
    internal func putText(for count: Int, _ make: @escaping @Sendable () -> String) {
        guard count > ClipboardPlugin.listedAtOnce else {
            put(make())
            return
        }
        overtake()
        let current = request
        // On a thread of the kernel's own: the shared queues may be busy with work that waits.
        BlockingCalls.run {
            let text = make()
            DispatchQueue.main.async { [self] in
                if current == request { write(text) }
            }
        }
    }

    /// Replaces what is on the clipboard with `text`.
    private func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    deinit {
        // Nothing to release.
    }
}
