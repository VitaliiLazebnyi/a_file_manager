public import Foundation

/// How a connection to an FTP server is secured (spec 11 › Address and URL syntax).
public enum TLSMode: Int, Codable, Equatable, Sendable {
    /// Plain FTP.
    case none = 0
    /// `AUTH TLS` on the plain control connection (`ftpes://`, and `ftps://` on any port but 990).
    case explicit = 1
    /// Encrypted from the first byte (`ftpis://`, and `ftps://` on port 990).
    case implicit = 2
}

/// What identifies a server in the URLs a panel shows: the scheme, the host and the port.
///
/// The user name is not part of it, so one server has one connection at a time.
public struct ServerKey: Hashable, CustomStringConvertible, Sendable {
    public static let schemes = ["ftp", "ftps", "sftp"]

    public let scheme: String
    public let host: String
    public let port: Int

    public init(scheme: String, host: String, port: Int? = nil) {
        self.scheme = scheme.lowercased()
        self.host = Self.canonical(host)
        // A port outside the range (a damaged or imported settings file) is not a port.
        self.port =
            port.flatMap { Self.validPorts.contains($0) ? $0 : nil } ?? Self.defaultPort(of: self.scheme)
    }

    public static let validPorts = 1...65_535

    /// Nil when the URL does not name a server of one of the network schemes.
    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), Self.schemes.contains(scheme), let host = url.host,
            !host.isEmpty
        else { return nil }
        self.init(scheme: scheme, host: host, port: url.port)
    }

    public static func defaultPort(of scheme: String) -> Int {
        scheme == "sftp" ? 22 : 21
    }

    /// An IPv6 address without the brackets it wears in a URL.
    static func bare(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    /// The one spelling of a host that is used as a key: without brackets, in lower case, and
    /// for a name with letters outside ASCII the form a URL gives back for it (the system
    /// writes `bücher.de` as `xn--bcher-kva.de`), so that the key made from an address the
    /// user typed and the key made from the panel's URL are the same server.
    static func canonical(_ host: String) -> String {
        let plain = bare(host).lowercased()
        guard !plain.utf8.allSatisfy({ $0 < 0x80 }) else {
            return plain
        }
        var components = URLComponents()
        components.scheme = "ftp"
        components.host = plain
        return components.url?.host.map { bare($0).lowercased() } ?? plain
    }

    /// The location of a path on this server, nil when the host cannot be written in a URL.
    ///
    /// It never carries a user name or password.
    public func validURL(path: String = "/") -> URL? {
        guard !host.isEmpty, Self.schemes.contains(scheme) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.contains(":") ? "[\(host)]" : host
        if port != Self.defaultPort(of: scheme), Self.validPorts.contains(port) { components.port = port }
        components.path = RemotePath.normalized(path)
        // The URL must name this server again, or it is not a location on it.
        guard let url = components.url, let back = url.host, Self.bare(back).lowercased() == host else {
            return nil
        }
        return url
    }

    /// The location of a path on this server.
    ///
    /// It never carries a user name or password. `ServerAddress` only accepts hosts that have a
    /// URL; a key made by hand from a host that has none gets a location on a server that does not
    /// exist (the reserved name `invalid`), never one on the local disk.
    public func url(path: String = "/") -> URL {
        // `host.invalid` of a known scheme always has a URL, so the second call ends there.
        validURL(path: path)
            ?? ServerKey(scheme: Self.schemes.contains(scheme) ? scheme : "ftp", host: "host.invalid").url(path: path)
    }

    /// `ftp://host:port`, as the server is named in menus and messages.
    public var description: String {
        // The location of the root, without the slash it ends with.
        String(url().absoluteString.dropLast())
    }
}

/// Paths on a server: always absolute, with `/` between the names.
public enum RemotePath {
    /// The names of a path, without empty ones, `.` and `..`.
    ///
    /// The path is cut at the bytes of the slash, as the server does: cut at characters, a slash
    /// followed by a combining mark would be one character and not a separator, and `a/<mark>..`
    /// would keep its `..`.
    private static func names(_ path: String) -> [ArraySlice<UInt8>] {
        var names: [ArraySlice<UInt8>] = []
        for name in Array(path.utf8).split(separator: 0x2F) {
            if name.elementsEqual([0x2E]) { continue }
            if name.elementsEqual([0x2E, 0x2E]) {
                _ = names.popLast()
                continue
            }
            names.append(name)
        }
        return names
    }

    /// Makes a path absolute and removes empty names, `.` and `..`.
    ///
    /// In the result every slash is a character of its own, for whoever reads the path as text:
    /// a name that begins with a combining mark (or ends with a character that joins what
    /// follows it) would otherwise melt into the slash next to it, and the path would read as
    /// having other names than it has. Such a name gets U+FFFD between itself and the slash. It
    /// is then not the name that was given, on purpose: nothing may be done to a neighbouring
    /// name by mistake. `hasSeparableNames` tells beforehand, and the file system refuses such paths.
    public static func normalized(_ path: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(path.utf8.count + 1)
        var isASCII = true
        for name in names(path) {
            bytes.append(0x2F)
            bytes.append(contentsOf: name)
            if isASCII, name.contains(where: { $0 >= 0x80 }) { isASCII = false }
        }
        // Cut at an ASCII byte, every piece is still valid UTF-8.
        if bytes.isEmpty {
            return "/"
        }
        let joined = String(decoding: bytes, as: UTF8.self)
        return isASCII ? joined : separated(joined)
    }

    /// Whether two scalars next to each other are two characters.
    private static func areApart(_ first: Unicode.Scalar, _ second: Unicode.Scalar) -> Bool {
        var pair = String.UnicodeScalarView()
        pair.append(first)
        pair.append(second)
        return String(pair).count == 2
    }

    /// `path` with every slash made a character of its own (see `normalized`).
    private static func separated(_ path: String) -> String {
        let scalars = Array(path.unicodeScalars)
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == "/" {
                if index > 0, scalars[index - 1] != "/", !areApart(scalars[index - 1], scalar) {
                    result.append("\u{FFFD}")
                }
                result.append(scalar)
                if index + 1 < scalars.count, scalars[index + 1] != "/", !areApart(scalar, scalars[index + 1]) {
                    result.append("\u{FFFD}")
                }
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// False for a path with a name that would melt into the slash before or after it when the
    /// path is read as text (see `normalized`).
    ///
    /// Such a path is not used: what it names cannot be told apart reliably from its neighbours.
    public static func hasSeparableNames(_ path: String) -> Bool {
        if path.utf8.allSatisfy({ $0 < 0x80 }) {
            return true
        }
        let scalars = Array(path.unicodeScalars)
        for (index, scalar) in scalars.enumerated() where scalar == "/" {
            if index > 0, scalars[index - 1] != "/", !areApart(scalars[index - 1], scalar) {
                return false
            }
            if index + 1 < scalars.count, scalars[index + 1] != "/", !areApart(scalar, scalars[index + 1]) {
                return false
            }
        }
        // The first and the last name have a slash next to them once the path is joined to another.
        if let first = scalars.first, first != "/", !areApart("/", first) {
            return false
        }
        if let last = scalars.last, last != "/", !areApart(last, "/") {
            return false
        }
        return true
    }

    public static func parent(of path: String) -> String? {
        let names = names(path)
        guard !names.isEmpty else {
            return nil
        }
        var bytes: [UInt8] = []
        for name in names.dropLast() {
            bytes.append(0x2F)
            bytes.append(contentsOf: name)
        }
        return bytes.isEmpty ? "/" : normalized(String(decoding: bytes, as: UTF8.self))
    }

    public static func name(of path: String) -> String {
        names(path).last.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public static func join(_ directory: String, _ name: String) -> String {
        normalized(directory + "/" + name)
    }

    /// The path of a URL as the server knows it.
    public static func of(_ url: URL) -> String {
        normalized(url.path)
    }
}

/// A server address as the user types it (spec 11 › Address and URL syntax): `host`,
/// `host:port`, `user@host:port` or `scheme://user:password@host:port/path`, where everything
/// but the host is optional.
///
/// The user name and the password are taken out of the text here and travel separately; the URLs
/// handed to the panels never contain them.
public struct ServerAddress: Equatable, Sendable {
    public var scheme: String
    public var tls: TLSMode
    public var host: String
    public var port: Int
    public var user: String?
    public var password: String?
    /// Absolute path on the server; `/` when none was given.
    public var path: String
    /// False when the text named no folder, so the server's start folder is meant.
    public var hasPath: Bool

    public init?(_ text: String, defaultScheme: String = "ftp") {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var scheme = defaultScheme
        var explicitTLS: TLSMode?
        if let range = rest.range(of: "://") {
            let prefix = rest[..<range.lowerBound].lowercased()
            switch prefix {
            case "ftp", "sftp":
                scheme = prefix

            case "ftps":
                scheme = "ftps"

            case "ftpes":
                (scheme, explicitTLS) = ("ftps", .explicit)

            case "ftpis":
                (scheme, explicitTLS) = ("ftps", .implicit)

            default:
                return nil
            }
            rest = String(rest[range.upperBound...])
        }
        var authority = rest
        var path = ""
        if let slash = rest.firstIndex(of: "/") {
            authority = String(rest[..<slash])
            path = String(rest[slash...])
        }
        // A password may contain `@`; the host cannot.
        if let at = authority.lastIndex(of: "@") {
            let credentials = authority[..<at]
            authority = String(authority[authority.index(after: at)...])
            if let colon = credentials.firstIndex(of: ":") {
                user = Self.decoded(credentials[..<colon])
                password = Self.decoded(credentials[credentials.index(after: colon)...])
            } else {
                user = Self.decoded(credentials)
            }
            if user?.isEmpty == true { user = nil }
        }
        var port: Int?
        var host = authority
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            // An IPv6 address in brackets, with the port after them.
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let tail = authority[authority.index(after: close)...]
            if tail.hasPrefix(":") {
                guard let number = Int(tail.dropFirst()) else {
                    return nil
                }
                port = number
            } else if !tail.isEmpty {
                return nil
            }
        } else if authority.filter({ $0 == ":" }).count == 1, let colon = authority.firstIndex(of: ":") {
            guard let number = Int(authority[authority.index(after: colon)...]) else {
                return nil
            }
            host = String(authority[..<colon])
            port = number
        }
        guard !host.isEmpty,
            host.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/@\\[]")))
                == nil,
            port.map({ ServerKey.validPorts.contains($0) }) ?? true
        else { return nil }
        // A host that cannot be written in a URL (`%`, `#`, `?`, quotes, direction marks) has no
        // location a panel could show.
        guard ServerKey(scheme: scheme, host: host, port: port).validURL() != nil else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        if scheme == "ftps" {
            tls = explicitTLS ?? (port == 990 ? .implicit : .explicit)
            self.port = port ?? (tls == .implicit ? 990 : 21)
        } else {
            tls = .none
            self.port = port ?? ServerKey.defaultPort(of: scheme)
        }
        hasPath = path.count > 1
        self.path = RemotePath.normalized(path.removingPercentEncoding ?? path)
    }

    private static func decoded(_ text: Substring) -> String {
        text.removingPercentEncoding ?? String(text)
    }

    public var key: ServerKey { ServerKey(scheme: scheme, host: host, port: port) }

    /// The location to show in a panel, without the user name and password.
    public var url: URL { key.url(path: path) }

    /// The address as it may be remembered and shown: with the user name, never with the password.
    public var textWithoutPassword: String {
        let text = key.url(path: hasPath ? path : "/").absoluteString
        guard let user, let range = text.range(of: "://") else {
            return text
        }
        return text.replacingCharacters(in: range, with: "://" + Self.escaped(user) + "@")
    }

    /// A user name as a URL writes it: what may not stand there as it is, as `%` and its bytes.
    private static func escaped(_ user: String) -> String {
        var text = ""
        for scalar in user.unicodeScalars {
            if CharacterSet.urlUserAllowed.contains(scalar) {
                text.unicodeScalars.append(scalar)
            } else {
                text += String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
            }
        }
        return text
    }
}

extension ServerAddress {
    /// An address of any scheme (`smb://user:password@host/share`, also without the scheme) as
    /// it may be remembered and shown: the password is taken out, the user name stays.
    ///
    /// A password may contain `/`, `?` and `#`, so the end of the server part cannot be found
    /// by the first of them alone: when the part before it holds a colon but no `@`, and an
    /// `@` follows later, what stands between that colon and the last `@` is taken for a
    /// password, unless it starts like a port (`host:445/share/a@b`). Rather a name too many
    /// taken out of a remembered address than a password shown.
    static func removingPassword(from text: String) -> String {
        let start = text.range(of: "://")?.upperBound ?? text.startIndex
        let rest = text[start...]
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        var at = authority.lastIndex(of: "@")
        if at == nil, let colon = authority.firstIndex(of: ":"), let later = rest[authorityEnd...].lastIndex(of: "@") {
            let afterColon = authority[authority.index(after: colon)...]
            let looksLikePort = !afterColon.isEmpty && afterColon.allSatisfy { $0.isASCII && $0.isNumber }
            if !looksLikePort { at = later }
        }
        guard let at, let colon = rest[..<at].firstIndex(of: ":") else {
            return text
        }
        var cleaned = text
        cleaned.removeSubrange(colon..<at)
        return cleaned
    }
}
