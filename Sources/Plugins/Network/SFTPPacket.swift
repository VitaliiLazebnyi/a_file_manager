import Foundation

/// One answer of the server: its type and what follows the request number.
internal struct SFTPPacket {
    /// The packet types the server sends.
    internal enum Kind: UInt8 {
        /// The answer to the first packet: the version and the extensions.
        case version = 2
        /// The success or error of a request.
        case status = 101
        /// The handle of an opened file or directory.
        case handle = 102
        /// The bytes a read brought.
        case data = 103
        /// Names: of a listing, or the one that `realpath` gives.
        case name = 104
        /// The attributes of a path or a handle.
        case attributes = 105
        /// The answer to an extended request.
        case extendedReply = 201
        /// Not a packet: the channel closed before an answer came.
        case closed = 0
    }

    /// What the packet is.
    internal let kind: Kind
    /// What follows the type and, for an answer, the request number.
    internal let body: Data

    /// The status code when this is a status packet.
    internal var statusCode: UInt32? {
        guard kind == .status else {
            return nil
        }
        var decoder = SFTPDecoder(body)
        return try? decoder.u32()
    }

    /// Throws unless the packet is the success status.
    internal func checkStatus() throws {
        if kind == .closed { throw NetworkError.connectionLost }
        guard kind == .status else { throw NetworkError.unexpected("SFTP packet \(kind.rawValue)") }
        var decoder = SFTPDecoder(body)
        let code = try decoder.u32()
        if code != 0 { throw SFTPError(code: code, message: (try? decoder.string()) ?? "") }
    }

    /// The payload of an answer of the expected kind, which is never a status: an error status
    /// is thrown, and so is a success where something else was expected.
    internal func expect(_ wanted: Kind) throws -> SFTPDecoder {
        if kind == .closed { throw NetworkError.connectionLost }
        if kind == .status { try checkStatus() }
        guard kind == wanted else { throw NetworkError.unexpected("SFTP packet \(kind.rawValue)") }
        return SFTPDecoder(body)
    }
}
