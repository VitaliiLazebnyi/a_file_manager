public import Foundation

/// How to reach and log in to one server: a saved connection, a quick connection, or what a
/// typed URL said.
public struct ConnectionProfile: Sendable {
    /// How an FTP connection opens its data connections.
    public enum DataConnection: Sendable {
        /// The client connects to the server (PORT, EPRT).
        case active
        /// The server waits for the client (PASV, EPSV).
        case passive
        /// As the preferences say (`NetworkOptions.Values.passiveByDefault`).
        case preferred

        /// Whether data connections are passive, given what the preferences say.
        internal func isPassive(byDefault passiveByDefault: Bool) -> Bool {
            switch self {
            case .active:
                return false

            case .passive:
                return true

            case .preferred:
                return passiveByDefault
            }
        }
    }

    /// The protocol, host and port of the server.
    public var key: ServerKey
    /// The name of the saved connection this came from.
    public var name: String?
    /// The identifier of the saved connection this came from; nil for any other.
    public var savedID: UUID?
    /// Whether and how FTP is protected by TLS.
    public var tls: TLSMode
    /// Nil: not known yet; the user is asked unless `anonymous` is set.
    public var user: String?
    /// The password to log in with; nil when it is not known yet.
    public var password: String?
    /// Whether the login is anonymous, with the password from the preferences.
    public var anonymous: Bool
    /// How FTP data connections are opened.
    public var dataConnection: DataConnection
    /// How file names are encoded on the server.
    public var encoding: NameEncoding
    /// Where to start; nil is the folder the login leads to.
    public var remoteDirectory: String?
    /// The commands sent after the login, in order.
    public var initCommands: [String]
    /// How FTP directories are listed: MLSD, LIST, or MLSD when the server offers it.
    public var listing: SavedConnection.Listing
    /// True for a server nobody chose to connect to: its address stood in a tab, a list or a
    /// link, and nothing is known of it.
    ///
    /// The user is asked before the first login.
    public var asksBeforeConnecting = false

    /// What the server is called in titles and the volume list.
    public var title: String { name ?? key.description }

    /// A profile for `key`; what is not given is not known yet or as the preferences say.
    ///
    /// Without `tls`, an `ftps:` address is implicit TLS on port 990 and explicit TLS on any other.
    public init(
        key: ServerKey,
        name: String? = nil,
        savedID: UUID? = nil,
        tls: TLSMode? = nil,
        user: String? = nil,
        password: String? = nil,
        anonymous: Bool = false,
        dataConnection: DataConnection = .preferred,
        encoding: NameEncoding = .automatic,
        remoteDirectory: String? = nil,
        initCommands: [String] = [],
        listing: SavedConnection.Listing = .automatic
    ) {
        self.key = key
        self.name = name
        self.savedID = savedID
        // An `ftps:` address that says nothing more: implicit on the port reserved for it, else explicit.
        self.tls = tls ?? (key.scheme == "ftps" ? (key.port == 990 ? .implicit : .explicit) : .plain)
        self.user = user
        self.password = password
        self.anonymous = anonymous
        self.dataConnection = dataConnection
        self.encoding = encoding
        self.remoteDirectory = remoteDirectory
        self.initCommands = initCommands
        self.listing = listing
    }
}
