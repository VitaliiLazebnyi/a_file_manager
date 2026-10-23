public import Foundation

/// What identifies a server in the URLs a panel shows: the scheme, the host and the port.
///
/// The user name is not part of it, so one server has one connection at a time.
public struct ServerKey: Hashable, CustomStringConvertible, Sendable {
    /// The schemes this plugin connects to itself; the others go to the system (`ServerSchemes.mountable`).
    public static let schemes = ["ftp", "ftps", "sftp"]

    /// The TCP ports a server can listen on.
    public static let validPorts = 1...65_535

    /// `ftp`, `ftps` or `sftp`, in lower case.
    public let scheme: String
    /// The host name or address, without brackets and in lower case (see `canonical(_:)`).
    public let host: String
    /// The port, the scheme's own when none or an impossible one was given.
    public let port: Int

    /// `ftp://host:port`, as the server is named in menus and messages.
    public var description: String {
        // The location of the root, without the slash it ends with.
        String(url().absoluteString.dropLast())
    }

    /// The key of `host` on `port` (the scheme's default port when nil or outside `validPorts`).
    public init(scheme: String, host: String, port: Int? = nil) {
        self.scheme = scheme.lowercased()
        self.host = Self.canonical(host)
        // A port outside the range (a damaged or imported settings file) is not a port.
        self.port =
            port.flatMap { Self.validPorts.contains($0) ? $0 : nil } ?? Self.defaultPort(of: self.scheme)
    }

    /// Nil when the URL does not name a server of one of the network schemes.
    public init?(_ url: URL) {
        guard let urlScheme = url.scheme?.lowercased(), Self.schemes.contains(urlScheme), let urlHost = url.host,
            !urlHost.isEmpty
        else { return nil }
        self.init(scheme: urlScheme, host: urlHost, port: url.port)
    }

    /// 22 for SFTP, 21 for FTP and FTPS (implicit FTPS on 990 is asked for with its port).
    public static func defaultPort(of scheme: String) -> Int {
        scheme == "sftp" ? 22 : 21
    }

    /// An IPv6 address without the brackets it wears in a URL.
    internal static func bare(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    /// The one spelling of a host that is used as a key: without brackets, in lower case, and
    /// for a name with letters outside ASCII the form a URL gives back for it (the system
    /// writes `bücher.de` as `xn--bcher-kva.de`), so that the key made from an address the
    /// user typed and the key made from the panel's URL are the same server.
    internal static func canonical(_ host: String) -> String {
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
            ?? Self(scheme: Self.schemes.contains(scheme) ? scheme : "ftp", host: "host.invalid").url(path: path)
    }
}
