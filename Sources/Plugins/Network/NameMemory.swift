internal import Foundation

/// The names of a server that would not reach it again as the bytes they came as, were they
/// written the usual way (composed, in the encoding of the connection): names in decomposed
/// form on a server that compares bytes, and names in another encoding than the one in use.
///
/// Each is kept, by its exact spelling, with the encoding that read it; a command that names it
/// writes it back unchanged in that encoding. Shared by the connections of a session. Safe from any
/// thread: all state is guarded by `lock`.
internal final class NameMemory: @unchecked Sendable {
    private static let capacity = 65_536

    private let lock = NSLock()
    private var spellings: [Data: String.Encoding] = [:]

    /// Whether no name is remembered, so every name is written the usual way.
    internal var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return spellings.isEmpty
    }

    /// Whether a name read with `encoding` needs to be remembered for a connection that
    /// writes names composed and in `sending`.
    internal static func needsRemembering(_ name: String, readAs encoding: String.Encoding, sending: String.Encoding)
        -> Bool
    {
        if encoding != sending {
            return true
        }
        // A name in ASCII is the same composed or not.
        if name.utf8.contains(where: { $0 >= 0x80 }) {
            return !name.precomposedStringWithCanonicalMapping.utf8.elementsEqual(name.utf8)
        }
        return false
    }

    /// The encoding to write a name in, by the UTF-8 bytes of its exact spelling; nil when it is not remembered.
    internal func encoding<Bytes: Sequence>(of name: Bytes) -> String.Encoding? where Bytes.Element == UInt8 {
        let key = Data(name)
        lock.lock()
        defer { lock.unlock() }
        return spellings[key]
    }

    /// Keeps a name with the encoding that read it; when the memory is full it starts again empty.
    internal func remember(_ name: String, encoding: String.Encoding) {
        lock.lock()
        defer { lock.unlock() }
        if spellings.count >= Self.capacity { spellings.removeAll() }
        spellings[Data(name.utf8)] = encoding
    }

    deinit {
        // Nothing to release.
    }
}
