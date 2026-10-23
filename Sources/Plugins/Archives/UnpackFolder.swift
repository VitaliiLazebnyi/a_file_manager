import AFMKernel
import Foundation

/// A folder on a disk of this machine that an archive is unpacked into, held open.
///
/// Everything below it is reached from its descriptor, one name at a time, and never through
/// a symbolic link (`openat` with `O_NOFOLLOW`): the folder a file is written into is the one
/// that was opened, whatever is done to the names on the way while the unpacking runs. A
/// path that is checked and then used again by name could be led elsewhere in between, by
/// whoever else may write to the target folder (a shared folder, `/tmp`): a folder taken
/// away and a link put in its place sends a path-based write to wherever the link points.
/// Here the write goes on into the folder that was opened, wherever that has been moved to.
///
/// **Threading.** Any number of threads at once; each call opens and closes what it needs.
internal final class UnpackFolder: Sendable {
    /// A file that `write` makes: where it goes below the folder and what it carries.
    internal struct NewFile {
        /// The names from the open folder down to the file, the file's own name last.
        internal let names: [String]
        /// Whether what stands under the name is replaced; without, it makes the write fail.
        internal let replacing: Bool
        /// The rights the archive stores, of which only those the user allows are given.
        internal let permissions: UInt16
        /// The time the file was last changed, as the archive stores it.
        internal let modified: Date
        /// The archive's mark (see `Quarantine`), which the file gets before it has its name.
        internal let quarantine: Data?
    }

    /// What the user allows new files to be (`umask`): rights an archive stores beyond that
    /// (a file anyone may write to) are not given, as `tar` and `unzip` do not give them.
    internal static let allowed: mode_t = {
        let mask = umask(0o022)
        umask(mask)
        return ~mask & 0o7777
    }()

    /// The folder that was opened, as the user chose it.
    internal let url: URL
    private let descriptor: Int32

    /// The folder itself is taken as it is, links on the way to it included: it is the place
    /// the user chose.
    ///
    /// Only what lies below it comes from the archive.
    internal init(_ url: URL) throws {
        self.url = url
        descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(errno, url.path) }
    }

    private static func mark(_ descriptor: Int32, _ quarantine: Data?) {
        guard let quarantine else {
            return
        }
        _ = quarantine.withUnsafeBytes { bytes in
            fsetxattr(descriptor, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, 0)
        }
    }

    /// Writes all of `block` to the open file `output`; `place` names it in an error.
    private static func write(_ block: Data, to output: Int32, place: String) throws {
        try block.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let written = retryingInterrupted {
                    Darwin.write(output, bytes.baseAddress?.advanced(by: done), bytes.count - done)
                }
                if written < 0 { throw posixError(errno, place) }
                done += written
            }
        }
    }

    /// Gives the open file `output` the time it was last changed.
    ///
    /// The time of access stays as it is. A time no file can have is left out.
    private static func setModified(_ modified: Date, of output: Int32) {
        let seconds = modified.timeIntervalSince1970.rounded(.down)
        if seconds.isFinite, abs(seconds) < 1e15 {
            let nanoseconds = ((modified.timeIntervalSince1970 - seconds) * 1e9).rounded(.down)
            var times = [
                timespec(tv_sec: 0, tv_nsec: Int((1 << 30) - 2)),
                timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
            ]
            futimens(output, &times)
        }
    }

    private func path(_ names: ArraySlice<String>) -> String {
        names.reduce(url.path) { $0 + "/" + $1 }
    }

    /// Opens the folder at `names` below this one, making what is missing; the caller closes
    /// the descriptor.
    ///
    /// Throws when a name on the way is a symbolic link or no folder.
    private func openFolder(_ names: ArraySlice<String>) throws -> Int32 {
        var current = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw posixError(errno, url.path) }
        for (index, name) in zip(names.indices, names) {
            // One name, and not a way up: checked here whatever the caller checked.
            guard PathSafety.isSafeName(name) else {
                close(current)
                throw ArchiveError.unsupported("Unpacking to the name \(name)")
            }
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            var next = openat(current, name, flags)
            if next < 0, errno == ENOENT {
                if mkdirat(current, name, 0o755) == 0 || errno == EEXIST { next = openat(current, name, flags) }
            }
            guard next >= 0 else {
                let code = errno
                var status = stat()
                let isLink =
                    fstatat(current, name, &status, AT_SYMLINK_NOFOLLOW) == 0 && status.st_mode & S_IFMT == S_IFLNK
                close(current)
                let place = path(names[...index])
                throw isLink
                    ? ArchiveError.unsupported("Unpacking through the symbolic link \(place)")
                    : posixError(code, place)
            }
            close(current)
            current = next
        }
        return current
    }

    /// Makes the folder at `names` (and those above it) and gives it the archive's mark.
    internal func makeFolder(_ names: [String], quarantine: Data?) throws {
        let folder = try openFolder(ArraySlice(names))
        defer { close(folder) }
        Self.mark(folder, quarantine)
    }

    /// Makes the symbolic link at `names`.
    ///
    /// One that stands there is replaced only with `replacing`.
    internal func makeLink(_ names: [String], to destination: String, replacing: Bool) throws {
        guard let name = names.last, PathSafety.isSafeName(name) else {
            throw ArchiveError.unsupported("Unpacking to an empty name")
        }
        let folder = try openFolder(names.dropLast())
        defer { close(folder) }
        if replacing { unlinkat(folder, name, 0) }
        guard symlinkat(destination, folder, name) == 0 else { throw posixError(errno, path(ArraySlice(names))) }
    }

    /// Writes `file`: `fill` writes the contents through the function it is given.
    ///
    /// The file arrives under a temporary name in the folder it belongs to and takes its name when
    /// `fill` has returned; when `fill` throws, nothing is left. What stands under the name is
    /// replaced only with `file.replacing` (a symbolic link there is replaced like a file, never
    /// written through); without, it makes the write fail. `opened` is called when the folder is
    /// open and before the file is made (tests).
    internal func write(
        _ file: NewFile,
        opened: (() -> Void)?,
        _ fill: ((Data) throws -> Void) throws -> Void
    ) throws {
        guard let name = file.names.last, PathSafety.isSafeName(name) else {
            throw ArchiveError.unsupported("Unpacking to an empty name")
        }
        let folder = try openFolder(file.names.dropLast())
        defer { close(folder) }
        opened?()
        let place = path(ArraySlice(file.names))
        let temporary = ".afm-\(UUID().uuidString).tmp"
        let output = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw posixError(errno, place) }
        var isOpen = true
        do {
            try fill { block in try Self.write(block, to: output, place: place) }
            Self.setModified(file.modified, of: output)
            guard fchmod(output, mode_t(file.permissions) & Self.allowed) == 0 else { throw posixError(errno, place) }
            // The mark is on the file before it appears under its name.
            Self.mark(output, file.quarantine)
            isOpen = false
            // The folder is on a disk of this machine, whose closing reports nothing: what was
            // written has already been taken.
            close(output)
            let moved =
                file.replacing
                ? renameat(folder, temporary, folder, name)
                : renameatx_np(folder, temporary, folder, name, UInt32(RENAME_EXCL))
            guard moved == 0 else { throw posixError(errno, place) }
        } catch {
            if isOpen { close(output) }
            unlinkat(folder, temporary, 0)
            throw error
        }
    }

    deinit {
        close(descriptor)
    }
}
