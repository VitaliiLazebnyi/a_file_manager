import AppKit
import PDFKit
import Quartz

/// Factories for the views that need no class of their own.
@MainActor
internal enum RichViews {
    /// What a Quick Look view shows: the file at a URL.
    private final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?

        init(_ url: URL) {
            previewItemURL = url
        }
    }

    /// A read-only text view in a scroll view: RTF (spec 10 › RTF) and printing.
    internal static func textView(_ text: NSAttributedString) -> (scroll: NSScrollView, text: NSTextView) {
        // A text view that is as wide as the scroll view and as tall as its text.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let view = NSTextView()
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        view.isEditable = false
        view.isSelectable = true
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.textStorage?.setAttributedString(text)
        view.usesFindBar = true
        let gate = LinkGate(opener: SystemLinks())
        view.delegate = gate
        gate.attach(to: view)
        return (scroll, view)
    }

    /// A PDF view scaled to the window, whose links go through a `LinkGate`.
    internal static func pdfView(_ document: PDFDocument) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        let gate = LinkGate(opener: SystemLinks())
        view.delegate = gate
        gate.attach(to: view)
        return view
    }

    /// The Mac's counterpart of Lister plugins and of the Explorer preview: whatever Quick
    /// Look can show (spec 10 › Explorer Preview).
    internal static func quickLookView(_ url: URL) -> QLPreviewView? {
        let view: QLPreviewView? = QLPreviewView(frame: .zero, style: .normal)
        view?.autostarts = true
        view?.previewItem = PreviewItem(url)
        return view
    }

    /// A line of explanation in place of a file that cannot be shown.
    internal static func message(_ text: String) -> NSView {
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
