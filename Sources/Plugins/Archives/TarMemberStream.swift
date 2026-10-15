import Foundation

/// The data of the member a `TarReader` stands on, as a stream.
final class TarMemberStream: ByteStream {
    private let reader: TarReader
    private let closesReader: Bool
    private var onClose: ((Bool) -> Void)?
    private var failed = false

    /// With `closesReader: false` the reader goes on to the next member afterwards; `onClose`
    /// is then told, once, that the reader is free again, and whether it can still be used
    /// (it cannot after an error).
    init(_ reader: TarReader, closesReader: Bool = true, onClose: ((Bool) -> Void)? = nil) {
        self.reader = reader
        self.closesReader = closesReader
        self.onClose = onClose
    }

    func read(upToCount count: Int) throws -> Data? {
        do {
            return try reader.readData(upToCount: count)
        } catch {
            failed = true
            throw error
        }
    }

    func close() {
        if closesReader { reader.close() }
        onClose?(!failed)
        onClose = nil
    }
}
