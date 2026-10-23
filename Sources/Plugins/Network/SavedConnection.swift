public import Foundation

/// A connection the user saved (spec 11 › "FTP: connection details" dialog).
///
/// The password is not part of it: it is kept in the Keychain under the connection's `id`.
public struct SavedConnection: Codable, Equatable, Sendable {
    /// The protocols in the order the dialog offers them.
    ///
    /// The raw values are what the settings file stores.
    public enum Kind: Int, Codable, CaseIterable, Sendable {
        /// Plain FTP.
        case ftp = 0
        /// FTP secured with `AUTH TLS` after connecting.
        case ftpExplicitTLS = 1
        /// FTP encrypted from the first byte, by custom on port 990.
        case ftpImplicitTLS = 2
        /// SFTP, over a secure shell.
        case sftp = 3

        /// The name the dialog shows.
        public var title: String {
            switch self {
            case .ftp:
                return "FTP"

            case .ftpExplicitTLS:
                return "FTP over TLS (explicit, AUTH TLS)"

            case .ftpImplicitTLS:
                return "FTP over TLS (implicit)"

            case .sftp:
                return "SFTP (secure shell)"
            }
        }

        /// The scheme of the locations on such a server: `ftp`, `ftps` or `sftp`.
        public var scheme: String {
            switch self {
            case .ftp:
                return "ftp"

            case .ftpExplicitTLS, .ftpImplicitTLS:
                return "ftps"

            case .sftp:
                return "sftp"
            }
        }

        /// How the control connection is secured; `.plain` for FTP and SFTP.
        public var tls: TLSMode {
            switch self {
            case .ftpExplicitTLS:
                return .explicit

            case .ftpImplicitTLS:
                return .implicit

            default:
                return .plain
            }
        }

        /// The port the protocol uses when none is given: 21, 990 for implicit TLS, 22 for SFTP.
        public var defaultPort: Int {
            switch self {
            case .ftpImplicitTLS:
                return 990

            case .sftp:
                return 22

            default:
                return 21
            }
        }

        /// The kind for a scheme and a TLS mode: SFTP for `sftp`, else FTP secured as `tls` says.
        public init(scheme: String, tls: TLSMode) {
            self =
                scheme == "sftp"
                ? .sftp : tls == .implicit ? .ftpImplicitTLS : tls == .explicit ? .ftpExplicitTLS : .ftp
        }
    }

    /// How directories are listed (spec 11 › Listing: MLSD or LIST).
    ///
    /// The raw values are what the settings file stores.
    public enum Listing: Int, Codable, CaseIterable, Sendable {
        /// MLSD when the server offers it, LIST otherwise.
        case automatic = 0
        /// Always LIST, read by the parser of the known listing formats.
        case list = 2
        /// Always MLSD, the machine-readable listing.
        case mlsd = 1

        /// The choices in the order the dialog offers them, which is the order of the raw values.
        public static let allCases: [Self] = [.automatic, .mlsd, .list]

        /// The name the dialog shows.
        public var title: String {
            switch self {
            case .automatic:
                return "Auto-detect (MLSD if offered)"

            case .list:
                return "Always LIST"

            case .mlsd:
                return "Always MLSD"
            }
        }
    }

    /// The names of the members in the settings file.
    private enum CodingKeys: String, CodingKey {
        case id = "id"
        case name = "name"
        case kind = "kind"
        case host = "host"
        case port = "port"
        case user = "user"
        case anonymous = "anonymous"
        case remoteDirectory = "remoteDirectory"
        case localDirectory = "localDirectory"
        case passive = "passive"
        case encoding = "encoding"
        case listing = "listing"
        case initCommands = "initCommands"
    }

    /// What identifies the connection, also when it is renamed; part of its password's account.
    public var id = UUID()
    /// The name in the list of connections; also what `FTPOPEN` looks for.
    public var name = ""
    /// The protocol.
    public var kind = Kind.ftp
    /// The host name or address, without the brackets of an IPv6 address.
    public var host = ""
    /// Nil is the protocol's usual port.
    public var port: Int?
    /// The user name; ignored when `anonymous` is set.
    public var user = ""
    /// Whether the login is anonymous, with the e-mail address of the preferences as password.
    public var anonymous = false
    /// The folder to open after the login; empty for the server's start folder.
    public var remoteDirectory = ""
    /// The local folder the other panel opens on connecting; empty to leave it.
    public var localDirectory = ""
    /// Whether FTP data connections are passive (the client connects) rather than active.
    public var passive = true
    /// How the server's file names are decoded.
    public var encoding = NameEncoding.automatic
    /// How directories are listed.
    public var listing = Listing.automatic
    /// Commands sent after the login, separated by `;`.
    public var initCommands = ""

    /// The server, with the protocol's port when none is given.
    public var key: ServerKey { ServerKey(scheme: kind.scheme, host: host, port: port ?? kind.defaultPort) }

    /// `host` or `host:port`, as the dialog shows it.
    public var hostText: String {
        let bare = host.contains(":") ? "[\(host)]" : host
        return port.map { "\(bare):\($0)" } ?? bare
    }

    /// The row in the list of connections.
    public var listTitle: String { "\(name)  —  \(key.description)" }

    /// The login this connection makes, without its password.
    public var profile: ConnectionProfile {
        ConnectionProfile(
            key: key,
            name: name.isEmpty ? nil : name,
            savedID: id,
            tls: kind.tls,
            user: anonymous || user.isEmpty ? nil : user,
            anonymous: anonymous,
            dataConnection: passive ? .passive : .active,
            encoding: encoding,
            remoteDirectory: remoteDirectory.isEmpty ? nil : RemotePath.normalized(remoteDirectory),
            initCommands: FTPServerConfig.initCommands(from: initCommands),
            listing: listing
        )
    }

    /// A new connection with a new identifier, plain FTP to no host yet.
    public init() {
        // Every member has its usual value.
    }

    /// Reads a connection from the settings, which a damaged or foreign file may have filled
    /// with anything: a member that is missing or of the wrong kind takes its usual value, and
    /// a port that is none (`-2`, `70000`) is the usual port.
    ///
    /// Only the identifier must be there.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
            (try? values.decodeIfPresent(Value.self, forKey: key)) ?? fallback
        }
        id = try values.decode(UUID.self, forKey: .id)
        name = read(.name, "")
        kind = read(.kind, Kind.ftp)
        host = read(.host, "")
        port = (try? values.decodeIfPresent(Int.self, forKey: .port))
            .flatMap { number in
                ServerKey.validPorts.contains(number) ? number : nil
            }
        user = read(.user, "")
        anonymous = read(.anonymous, false)
        remoteDirectory = read(.remoteDirectory, "")
        localDirectory = read(.localDirectory, "")
        passive = read(.passive, true)
        encoding = read(.encoding, NameEncoding.automatic)
        listing = read(.listing, Listing.automatic)
        initCommands = read(.initCommands, "")
    }

    /// Fills host, port, protocol and user from what was typed into the host field, which may
    /// be a plain name, `host:port`, or a whole address with a scheme.
    ///
    /// False when it is none of these.
    public mutating func setHost(_ text: String, kind chosen: Kind) -> Bool {
        guard let address = ServerAddress(text, defaultScheme: chosen.scheme) else {
            return false
        }
        let hasScheme = text.contains("://")
        kind = hasScheme ? Kind(scheme: address.scheme, tls: address.tls) : chosen
        host = address.host
        let typedPort = address.port
        // A port is only stored when it is not the one the protocol uses anyway.
        let typed = text.contains(":\(typedPort)")
        port = typed && typedPort != kind.defaultPort ? typedPort : nil
        if let typedUser = address.user { (user, anonymous) = (typedUser, false) }
        if address.hasPath, remoteDirectory.isEmpty { remoteDirectory = address.path }
        return true
    }

    /// Stores `port`, unless it is the one the protocol uses anyway.
    internal mutating func setPort(_ port: Int) {
        self.port = port == kind.defaultPort ? nil : port
    }
}
