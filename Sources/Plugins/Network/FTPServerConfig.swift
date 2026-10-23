public import Foundation

/// Everything needed to log in to one FTP server.
public struct FTPServerConfig: Sendable {
    /// The server's host name or address.
    public var host: String
    /// The port of the control connection, 21 unless the server says otherwise.
    public var port: Int
    /// Whether and how the connection is encrypted.
    public var tls: TLSMode
    /// The user name sent with USER.
    public var user: String
    /// The password sent with PASS; never written to the log.
    public var password: String
    /// Passive: this program opens the data connections.
    ///
    /// Otherwise the server connects back.
    public var passive: Bool
    /// How file names travel on the control connection.
    public var encoding: NameEncoding
    /// Seconds to wait for an answer or for data.
    public var timeout: TimeInterval
    /// Commands sent after the login (spec 11 › Login sequence, Send Commands).
    public var initCommands: [String]
    /// MLSD or LIST for listings: automatic uses MLSD when the server offers it, the others insist
    /// (spec 11 › Listing: MLSD or LIST).
    public var listing: SavedConnection.Listing

    /// A configuration; what is left out is the anonymous login on port 21 without encryption.
    public init(
        host: String,
        port: Int = 21,
        tls: TLSMode = .plain,
        user: String = "anonymous",
        password: String = "",
        passive: Bool = true,
        encoding: NameEncoding = .automatic,
        timeout: TimeInterval = 30,
        initCommands: [String] = [],
        listing: SavedConnection.Listing = .automatic
    ) {
        self.host = host
        self.port = port
        self.tls = tls
        self.user = user
        self.password = password
        self.passive = passive
        self.encoding = encoding
        self.timeout = timeout
        self.initCommands = initCommands
        self.listing = listing
    }

    /// Splits the *Send Commands* field at `;`; `;;` stands for a semicolon inside a command.
    public static func initCommands(from text: String) -> [String] {
        let marker = "\u{1}"
        return text.replacingOccurrences(of: ";;", with: marker)
            .split(separator: ";")
            .map { command in command.replacingOccurrences(of: marker, with: ";").trimmingCharacters(in: .whitespaces) }
            .filter { command in !command.isEmpty }
    }
}
