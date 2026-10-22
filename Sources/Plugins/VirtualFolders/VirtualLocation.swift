import AFMKernel
public import Foundation

/// What a `vfolder:` URL stands for. Everything a virtual folder needs to find its way back to
/// the real file system is written into the URL itself, so a tab that shows one can be stored
/// and restored like any other, and `parent(of:)` needs no memory:
///
///     vfolder://branch.h66696c653a2f2f/Users/x/dir          the branch view of file:///Users/x/dir
///     vfolder://pick.n3.h66696c653a2f2f/Users/x/dir         the same, for the items registered as 3
///     vfolder://list.n7.h66696c653a2f2f/Users/x/dir/Title   the file list 7, opened from that folder
///
/// The path is the real directory's path. The host names the kind, the number of a registered
/// list, and (in hex, because a host may hold little else) the part of the real URL in front of
/// its path: scheme, user, host and port.
public enum VirtualLocation: Equatable {
    /// Every file below a directory in one list (spec 03 › Branch view).
    case branch(of: URL)
    /// The branch view of some items of a directory only (spec 03 › Selected branch).
    case picked(id: Int, in: URL)
    /// A list of files from anywhere (spec 09 › Feed to listbox). `origin` is the real
    /// directory the panel showed before; `[..]` leads back to it.
    case list(id: Int, title: String, origin: URL?)

    public static let scheme = "vfolder"

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .branch(let real):
            components.host = "branch" + Self.hexLabels(Self.prefix(of: real))
            components.path = Self.path(of: real)

        case .picked(let id, let real):
            components.host = "pick.n\(id)" + Self.hexLabels(Self.prefix(of: real))
            components.path = Self.path(of: real)

        case .list(let id, let title, let origin):
            components.host =
                "list.n\(id)" + (origin.map { Self.hexLabels(Self.prefix(of: $0)) } ?? "")
            let folder = origin.map(Self.path(of:)) ?? ""
            components.path = (folder == "/" ? "" : folder) + "/" + Self.pathComponent(title)
        }
        // Scheme, host and path are all of a form a URL takes (the path starts with `/` and is
        // escaped as it is set, the host holds letters, digits, dots and `-` only), so a URL
        // always comes out.
        // swiftlint:disable:next force_unwrapping
        return components.url!
    }

    internal var isList: Bool {
        if case .list = self {
            return true
        }
        return false
    }

    /// The real directory `[..]` leads to; nil for a list that was not opened from a folder.
    public var realDirectory: URL? {
        switch self {
        case .branch(let real), .picked(_, let real):
            return real

        case .list(_, _, let origin):
            return origin
        }
    }

    /// Reads a URL of the virtual scheme; nil for every other URL and for what is not one of
    /// the forms above.
    public init?(_ url: URL) {
        guard url.scheme == Self.scheme, let host = url.host else {
            return nil
        }
        let labels = host.split(separator: ".").map(String.init)
        guard let kind = labels.first else {
            return nil
        }
        let id = labels.dropFirst().first { $0.hasPrefix("n") }.flatMap { Int($0.dropFirst()) }
        let hex = labels.dropFirst().filter { $0.hasPrefix("h") }.map { $0.dropFirst() }.joined()
        guard let prefix = Self.text(fromHex: hex) else {
            return nil
        }
        let path = url.path.isEmpty ? "/" : url.path
        switch kind {
        case "branch":
            guard let real = Self.realURL(prefix: prefix, path: path) else {
                return nil
            }
            self = .branch(of: real)

        case "pick":
            guard let id, let real = Self.realURL(prefix: prefix, path: path) else {
                return nil
            }
            self = .picked(id: id, in: real)

        case "list":
            guard let id else {
                return nil
            }
            // The path starts with a slash, so the folder is at least the root.
            let folder = (path as NSString).deletingLastPathComponent
            let origin = prefix.isEmpty ? nil : Self.realURL(prefix: prefix, path: folder)
            self = .list(id: id, title: (path as NSString).lastPathComponent, origin: origin)

        default:
            return nil
        }
    }

    /// A title cannot hold a path separator, because it is one component of the URL's path.
    internal static func pathComponent(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: ":").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "List" : cleaned
    }

    /// The path of a real location; `URL.path` has no trailing slash already.
    private static func path(of real: URL) -> String {
        // Plain and from the root, also for a location given relative to nothing.
        plain(real.path)
    }

    /// What stands in front of the path of a real URL: `file://`, `sftp://user@host:22`.
    ///
    /// A password is left out: this is written into tabs, history and the hotlist, which must not
    /// hold one.
    private static func prefix(of real: URL) -> String {
        var text = (real.scheme ?? "file") + "://"
        if let user = real.user(percentEncoded: true) { text += user + "@" }
        // An IPv6 address stands in brackets, so that its colons are not taken for the port's.
        if let host = real.host(percentEncoded: true) { text += host.contains(":") ? "[" + host + "]" : host }
        if let port = real.port { text += ":\(port)" }
        return text
    }

    private static func realURL(prefix: String, path: String) -> URL? {
        // Written into a URL by anyone, so the path is made plain: no `..` leads out of the place.
        let path = Self.plain(path)
        if prefix == "file://" {
            return URL(fileURLWithPath: path, isDirectory: false)
        }
        // The prefix holds scheme, user, host and port only; anything else in it is not ours.
        guard var components = URLComponents(string: prefix), components.scheme != nil,
            components.path.isEmpty, components.query == nil, components.fragment == nil, components.password == nil
        else { return nil }
        components.path = path
        return components.url
    }

    /// A path without `.` and `..` components and empty ones, resolved on the text alone; it
    /// starts with a slash.
    internal static func plain(_ path: String) -> String {
        var kept: [String] = []
        // By scalars: a slash followed by a combining mark is not a separator to `Character`.
        for scalars in path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(String.UnicodeScalarView(scalars))
            if component.utf8.elementsEqual("..".utf8) {
                _ = kept.popLast()
                continue
            }
            if component.utf8.elementsEqual(".".utf8) { continue }
            kept.append(component)
        }
        return "/" + kept.joined(separator: "/")
    }

    /// Host labels of at most 61 characters each (a label may not be longer than 63).
    private static func hexLabels(_ text: String) -> String {
        let hex = text.utf8.map { String(format: "%02x", $0) }.joined()
        var labels = ""
        var rest = Substring(hex)
        while !rest.isEmpty {
            labels += ".h" + rest.prefix(60)
            rest = rest.dropFirst(60)
        }
        return labels
    }

    private static func text(fromHex hex: String) -> String? {
        guard hex.count % 2 == 0 else {
            return nil
        }
        var bytes: [UInt8] = []
        var rest = Substring(hex)
        while !rest.isEmpty {
            guard let byte = UInt8(rest.prefix(2), radix: 16) else {
                return nil
            }
            bytes.append(byte)
            rest = rest.dropFirst(2)
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
