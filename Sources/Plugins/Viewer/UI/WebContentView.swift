import AppKit
import WebKit

/// HTML shown as a page: scripts do not run and nothing is loaded from elsewhere, so a file is
/// safe to look at.
///
/// The page is shown once, from the string; every navigation after that is refused (a `<meta
/// http-equiv="refresh">` and a script-less redirect are navigations too, and would load a page of
/// the web into the viewer), and a link that was clicked is handed to `onLink`. Main thread only.
internal final class WebContentView: NSView, WKNavigationDelegate {
    /// What a navigation is allowed to do: the first one (the page, from a string), a jump to a
    /// place in the page (`#name`), and nothing else.
    internal enum Decision: Equatable {
        /// The navigation goes ahead.
        case allow
        /// The navigation is refused.
        case cancel
        /// The navigation is refused, and the link is handed to `onLink`.
        case followLink
    }

    /// Forbids every load but inline styles and images that are part of the page itself.
    internal static let policy =
        "<meta http-equiv=\"Content-Security-Policy\" "
        + "content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:\">"

    private let webView: WKWebView
    /// Receives a link that was clicked; the view itself never follows one.
    internal var onLink: (URL) -> Void = { _ in
        // A link goes nowhere until the pane sets this.
    }
    /// Whether the load of the page itself is still to come.
    private var expectsPage = false

    /// A web view without JavaScript and without a store of its own on the disk.
    override internal init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        super.init(frame: frame)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    /// Made in code only: an archive gives none.
    internal required init?(coder _: NSCoder) { nil }

    /// What is done with a navigation of the main frame or another (`isMainFrame`), clicked or not, to `url`;
    /// `expectsPage` while the page itself is still to be loaded.
    nonisolated internal static func decide(
        isMainFrame: Bool,
        isLinkClick: Bool,
        url: URL?,
        expectsPage: Bool
    ) -> Decision {
        let isBlank =
            url.map { link in
                link.scheme == "about"
                    && (link.absoluteString == "about:blank" || link.absoluteString.hasPrefix("about:blank#"))
            } ?? false
        if isLinkClick {
            // A jump inside the page stays in the page.
            if isMainFrame, isBlank, url?.fragment != nil {
                return .allow
            }
            return url == nil ? .cancel : .followLink
        }
        // The page itself, the one time (WebKit names it `about:blank`, or has no name for it when
        // it comes from a string): anything later (a refresh, a redirect, a frame) is refused.
        let isString = url == nil || url?.scheme == "about" || url?.scheme == "applewebdata"
        if expectsPage, isMainFrame, isString {
            return .allow
        }
        return .cancel
    }

    /// Shows `html` as a page, under `policy`.
    internal func show(html: String) {
        expectsPage = true
        webView.loadHTMLString(Self.policy + html, baseURL: nil)
    }

    /// Asks `policy(isMainFrame:isLinkClick:url:)` about every navigation of the web view.
    internal func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(
            policy(
                isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                isLinkClick: navigationAction.navigationType == .linkActivated,
                url: navigationAction.request.url
            )
        )
    }

    /// What is done with a navigation (`decide`): the page is let in once, a clicked link is
    /// handed to `onLink`.
    internal func policy(isMainFrame: Bool, isLinkClick: Bool, url: URL?) -> WKNavigationActionPolicy {
        switch Self.decide(isMainFrame: isMainFrame, isLinkClick: isLinkClick, url: url, expectsPage: expectsPage) {
        case .allow:
            if !isLinkClick { expectsPage = false }
            return .allow

        case .followLink:
            if let url { onLink(url) }
            return .cancel

        case .cancel:
            return .cancel
        }
    }

    /// The operation that prints the page as it is shown.
    internal func printOperation(with info: NSPrintInfo) -> NSPrintOperation { webView.printOperation(with: info) }
}
