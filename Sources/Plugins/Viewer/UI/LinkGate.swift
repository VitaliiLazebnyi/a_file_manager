import AppKit
import PDFKit

/// The delegate of the views that show RTF and PDF: a click on a link opens a web page or a
/// mail and nothing else (the framework would open any URL, a file or a share included).
@MainActor
internal final class LinkGate: NSObject, NSTextViewDelegate, @preconcurrency PDFViewDelegate {
    private static var key = 0

    /// Where the links it lets through go (tests put their own in).
    private let opener: any LinkOpening

    /// A gate that hands the links it lets through to `opener`.
    internal init(opener: any LinkOpening) {
        self.opener = opener
    }

    /// Keeps the gate alive for as long as `view` is (the views hold their delegates weakly).
    internal func attach(to view: NSObject) {
        objc_setAssociatedObject(view, &Self.key, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Opens `link` (a URL, or its text) when `LinkPolicy` lets it go to the browser or the mail program.
    internal func open(_ link: Any) {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        if let url, LinkPolicy.opensInBrowser(url) { opener.open(url) }
    }

    /// A link in an RTF text was clicked: the gate decides, the text view does nothing more.
    internal func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
        open(link)
        // Handled: the text view does not open it again.
        return true
    }

    /// A link in a PDF was clicked: the gate decides instead of the PDF view.
    internal func pdfViewWillClick(onLink _: PDFView, with url: URL) {
        open(url)
    }
}
