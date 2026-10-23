import Foundation

/// A file on the local disk that is read at any position, from any number of threads at once
/// (`pread` keeps no position).
///
/// The file stays readable for as long as this object lives, even when it is replaced or deleted
/// meanwhile.
internal final class RandomAccessFile: Sendable {
    /// The size of the file when it was opened.
    internal let size: UInt64
    /// The path the file is known by in messages and to child processes.
    internal let path: String
    /// What the open file is, taken from the descriptor: a file that has since been replaced
    /// under the same path has another.
    internal let signature: FileSignature
    private let descriptor: Int32

    /// False when another file lies at the path now: a child process that opens the path
    /// would read that one.
    internal var isStillAtItsPath: Bool { FileSignature.of(path) == signature }

    /// Opens the file at `url` for reading; throws the system's error when it cannot be opened.
    ///
    /// `shownAs` names the file in messages and to child processes when it is opened under a
    /// temporary name that it is about to lose.
    internal init(_ url: URL, shownAs: String?) throws {
        path = shownAs ?? url.path
        descriptor = open(url.path, O_RDONLY)
        var status = stat()
        guard descriptor >= 0, fstat(descriptor, &status) == 0 else {
            let code = errno
            // (Closing -1, a file that did not open, does nothing.)
            Darwin.close(descriptor)
            throw posixError(code, path)
        }
        size = UInt64(status.st_size)
        signature = FileSignature(status)
    }

    /// Up to `count` bytes; fewer only at the end of the file.
    internal func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < size else {
            return Data()
        }
        let wanted = Int(min(UInt64(count), size - offset))
        // Read straight into the block that is handed on: nothing is cleared first or copied after.
        guard let buffer = malloc(wanted) else { throw posixError(ENOMEM, path) }
        var done = 0
        while done < wanted {
            let got = retryingInterrupted {
                pread(descriptor, buffer + done, wanted - done, off_t(offset) + off_t(done))
            }
            if got < 0 {
                let code = errno
                free(buffer)
                throw posixError(code, path)
            }
            if got == 0 { break }
            done += got
        }
        guard done > 0 else {
            free(buffer)
            return Data()
        }
        return Data(bytesNoCopy: buffer, count: done, deallocator: .free)
    }

    deinit { Darwin.close(descriptor) }
}
