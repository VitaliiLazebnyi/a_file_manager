import AFMShell
import AppKit

/// A window that shows a text: the keyboard help and the "what is where" page.
internal final class TextWindowController: NSWindowController {
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 560))

    /// A window titled `title` with a read-only monospaced text, not yet on screen.
    internal init(title: String) {
        let window = ToolWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.usesFindBar = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        window.contentView = scroll
    }

    /// Not used: the window is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) { fatalError("not used") }

    /// Shows `text`; `present` puts the window on screen.
    internal func show(_ text: String, present: (NSWindowController) -> Void) {
        textView.string = text
        present(self)
        window?.makeFirstResponder(textView)
    }
}
