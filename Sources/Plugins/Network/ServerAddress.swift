public import Foundation

/// A server address as the user types it (spec 11 › Address and URL syntax): `host`,
/// `host:port`, `user@host:port` or `scheme://user:password@host:port/path`, where everything
/// but the host is optional.
///
/// The user name and the password are taken out of the text here and travel separately; the URLs
/// handed to the panels never contain them.
public struct ServerAddress: Equatable, Sendable {
    /// `ftp`, `ftps` or `sftp`, in lower case.
    public var scheme: String
    /// How an FTPS connection is secured; `.plain` for FTP and SFTP.
    public var tls: TLSMode
    /// The host name or address as typed, without the brackets of an IPv6 address.
    public var host: String
    /// The port typed, or the scheme's own (990 for implicit FTPS).
    public var port: Int
    /// The user name, percent-decoded; nil when none was typed.
    public var user: String?
    /// The password, percent-decoded; nil when none was typed.
    public var password: String?
    /// Absolute path on the server; `/` when none was given.
    public var path: String
    /// False when the text named no folder, so the server's start folder is meant.
    public var hasPath: Bool

    /// The server this address names, which identifies its connection.
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

    /// Reads an address the user typed; nil when it names no server this plugin can reach.
    ///
    /// `defaultScheme` is used when the text has no `scheme://`. `ftpes://` and `ftpis://` are FTPS with the TLS mode
    /// they name; plain `ftps://` is implicit on port 990 and explicit on any other.
    public init?(_ text: String, defaultScheme: String = "ftp") {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let named = Self.takingScheme(from: &rest, defaultScheme: defaultScheme) else {
            return nil
        }
        var authority = rest
        var folder = ""
        if let slash = rest.firstIndex(of: "/") {
            authority = String(rest[..<slash])
            folder = String(rest[slash...])
        }
        let credentials = Self.takingCredentials(from: &authority)
        guard let server = Self.hostAndPort(of: authority),
            Self.isUsable(host: server.host, port: server.port, scheme: named.scheme)
        else { return nil }
        scheme = named.scheme
        host = server.host
        user = credentials.user
        password = credentials.password
        if named.scheme == "ftps" {
            tls = named.tls ?? (server.port == 990 ? .implicit : .explicit)
            port = server.port ?? (tls == .implicit ? 990 : 21)
        } else {
            tls = .plain
            port = server.port ?? ServerKey.defaultPort(of: named.scheme)
        }
        hasPath = folder.count > 1
        path = RemotePath.normalized(folder.removingPercentEncoding ?? folder)
    }

    /// Takes `scheme://` off the front of `rest`: the scheme and, for `ftpes` and `ftpis`, the TLS mode it names.
    ///
    /// Returns `defaultScheme` and no mode when the text has no scheme, nil for a scheme this plugin does not
    /// connect to.
    private static func takingScheme(
        from rest: inout String,
        defaultScheme: String
    ) -> (scheme: String, tls: TLSMode?)? {
        guard let range = rest.range(of: "://") else {
            return (defaultScheme, nil)
        }
        let prefix = rest[..<range.lowerBound].lowercased()
        rest = String(rest[range.upperBound...])
        switch prefix {
        case "ftp", "ftps", "sftp":
            return (prefix, nil)

        case "ftpes":
            return ("ftps", .explicit)

        case "ftpis":
            return ("ftps", .implicit)

        default:
            return nil
        }
    }

    /// Takes `user:password@` off the front of `authority` and returns both, decoded; an empty user name is none.
    ///
    /// A password may contain `@`; the host cannot, so the last `@` ends them.
    private static func takingCredentials(from authority: inout String) -> (user: String?, password: String?) {
        guard let atSign = authority.lastIndex(of: "@") else {
            return (nil, nil)
        }
        let credentials = authority[..<atSign]
        authority = String(authority[authority.index(after: atSign)...])
        let colon = credentials.firstIndex(of: ":")
        let name = decoded(credentials[..<(colon ?? credentials.endIndex)])
        let secret = colon.map { decoded(credentials[credentials.index(after: $0)...]) }
        return (name.isEmpty ? nil : name, secret)
    }

    /// The host and the port of `host`, `host:port`, `[address]` or `[address]:port` (IPv6 in brackets).
    ///
    /// Nil when the port is not a number or something else follows the brackets. A host with more than one colon is
    /// an IPv6 address without brackets, and has no port.
    private static func hostAndPort(of authority: String) -> (host: String, port: Int?)? {
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            let address = String(authority[authority.index(after: authority.startIndex)..<close])
            let tail = authority[authority.index(after: close)...]
            if tail.isEmpty {
                return (address, nil)
            }
            guard tail.hasPrefix(":"), let number = Int(tail.dropFirst()) else {
                return nil
            }
            return (address, number)
        }
        guard authority.filter({ $0 == ":" }).count == 1, let colon = authority.firstIndex(of: ":") else {
            return (authority, nil)
        }
        guard let number = Int(authority[authority.index(after: colon)...]) else {
            return nil
        }
        return (String(authority[..<colon]), number)
    }

    /// Whether `host` and `port` can name a server in a panel's location.
    ///
    /// The host must not be empty nor hold blanks, `/`, `@`, `\` or brackets, the port must be one, and the two must
    /// make a URL: a host with `%`, `#`, `?`, quotes or direction marks has no location a panel could show.
    private static func isUsable(host: String, port: Int?, scheme: String) -> Bool {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/@\\[]"))
        guard !host.isEmpty,
            !host.unicodeScalars.contains(where: forbidden.contains),
            port.map({ ServerKey.validPorts.contains($0) }) ?? true
        else { return false }
        return ServerKey(scheme: scheme, host: host, port: port).validURL() != nil
    }

    /// `text` with its percent escapes decoded; as it is when they do not decode to UTF-8.
    private static func decoded(_ text: Substring) -> String {
        text.removingPercentEncoding ?? String(text)
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
