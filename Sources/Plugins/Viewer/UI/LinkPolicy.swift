import AFMKernel
import Foundation

/// What a link in a file that is viewed may do.
///
/// A file is untrusted: a click on a link in it opens a web page or a mail in the program for that,
/// and the viewer follows only links to files beside the one shown. Everything else (`file:`,
/// `smb:`, `ftp:`, `sftp:`, the URL schemes of other programs) does nothing.
internal enum LinkPolicy {
    /// Whether the link is a web page (`http`, `https`, with a host) or a mail (`mailto`), which the
    /// browser or the mail program may open.
    internal static func opensInBrowser(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        if scheme == "mailto" {
            return true
        }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    /// The file a link names when the viewer may load it: a relative link, resolved against
    /// `base`, that lies in the folder of `base` or below it, on the same file system (the same
    /// scheme, host and port).
    ///
    /// Nil otherwise.
    internal static func target(of link: URL, relativeTo base: URL) -> URL? {
        let text = link.relativeString.replacingOccurrences(of: "about:blank", with: "")
        // A link with a scheme of its own (an absolute one) is not relative.
        if let own = URL(string: text)?.scheme, own.lowercased() != base.scheme?.lowercased() {
            return nil
        }
        guard !text.isEmpty, let resolved = URL(string: text, relativeTo: base),
            var parts = URLComponents(url: resolved.absoluteURL, resolvingAgainstBaseURL: true)
        else { return nil }
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
        guard target.isInside(folder) else {
            return nil
        }
        return target
    }
}
