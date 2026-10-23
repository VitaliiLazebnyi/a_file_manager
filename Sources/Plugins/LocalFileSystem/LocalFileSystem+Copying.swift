public import AFMKernel
public import Foundation

/// Copying one file or one link, by the system's `copyfile`.
extension LocalFileSystem {
    /// What the system's progress callback needs, handed to it as the context pointer: the
    /// callback is a C function, which cannot capture.
    private final class CopyProgress {
        let report: CopyReport
        let interruption: Interruption
        let stops: (@Sendable (Int32, Int32) -> Bool)?
        var stopped = false

        init(_ report: CopyReport, _ interruption: Interruption, stops: (@Sendable (Int32, Int32) -> Bool)?) {
            (self.report, self.interruption, self.stops) = (report, interruption, stops)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// Data, attributes, permissions and extended attributes; clone instead of copying when
    /// possible; and only ever to a name that is free at the moment the copy is made (a file
    /// another program put there after the check stays as it is).
    ///
    /// Neither end is followed if a link is put there since the check; holes of a sparse file stay
    /// holes (a disk image copied to another volume is not written out in full).
    private static let copyFlags: copyfile_flags_t = {
        let (clone, exclusive, noFollow, sparse) = (
            copyfile_flags_t(1 << 24), copyfile_flags_t(1 << 17), copyfile_flags_t(3 << 18),
            copyfile_flags_t(1 << 27)
        )
        return copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA) | clone | exclusive
            | noFollow | sparse
    }()

    /// Refuses what is not a regular file or a link (as `status` describes `source`).
    private static func requireCopyable(_ status: stat, _ source: URL) throws {
        switch status.st_mode & S_IFMT {
        case S_IFREG, S_IFLNK:
            break

        case S_IFDIR:
            throw posixError(EISDIR, source)

        default:
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [
                    NSLocalizedDescriptionKey: "\(source.path) is not an ordinary file or a link and is not copied."
                ]
            )
        }
    }

    /// Has the system report every step of the copy made with `state` to `context`.
    private static func follow(_ state: copyfile_state_t?, with context: CopyProgress) {
        let callback: copyfile_callback_t = { what, stage, state, _, _, context in
            // (The context is always set, below.)
            let progress = Unmanaged<CopyProgress>.fromOpaque(context.unsafelyUnwrapped).takeUnretainedValue()
            // A write that failed ends the copy, with its error. Going on would have the system try
            // the same write again, and on a full or vanished disk it would do so for ever.
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_ERR {
                return COPYFILE_QUIT
            }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                if !progress.report(Int64(copied)) { progress.stopped = true }
            }
            // Every step the system reports (the start and end of the data, each extended
            // attribute) is a place to stop for a caller that has set its flag.
            if progress.interruption.isInterrupted || progress.stops?(what, stage) == true { progress.stopped = true }
            return progress.stopped ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
    }

    /// Regular files are cloned where the volume allows it, otherwise copied block by block;
    /// links are copied as links.
    ///
    /// Nothing else is copied here: a folder is a tree, which only the caller can copy with
    /// progress and a way to stop, and a pipe or a device is not something to read the contents of.
    public func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try withoutActuallyEscaping(progress) { progress in
            let report = CopyReport(progress)
            defer { report.detach() }
            try copyItem(source, to: destination, LocalCall(probes), report)
        }
    }

    /// With a flag the copy ends not only when `progress` says so: a read or write that
    /// waits is ended by a signal, the flag is looked at between the steps the system
    /// reports (every block of data, every extended attribute), and on a share the copy
    /// runs where the caller can leave it behind (`RemoteChanges`).
    ///
    /// `progress` is then called on that other thread, while the caller waits, and never after this
    /// has returned. What a stopped copy has written is removed, by this call or, if it was left
    /// behind, by its thread when the system lets it go.
    public func copy(_ source: URL, to destination: URL, cancellation: CancellationFlag, progress: (Int64) -> Bool)
        throws
    {
        try withoutActuallyEscaping(progress) { progress in
            let report = CopyReport(progress)
            defer { report.detach() }
            try change(at: destination, cancellation) { try self.copyItem(source, to: destination, $0, report) }
        }
    }

    /// Copies one file or link to a name that must be free; an existing file is never touched,
    /// not even on failure.
    private func copyItem(_ source: URL, to destination: URL, _ call: LocalCall, _ report: CopyReport) throws {
        var status = stat()
        if try call.run(destination.path, { lstat(destination.path, &status) }) == 0 {
            throw FileSystemError.alreadyExists(destination.path)
        }
        guard try call.run(source.path, { lstat(source.path, &status) }) == 0 else {
            throw Self.posixError(errno, source)
        }
        try Self.requireCopyable(status, source)
        let context = CopyProgress(report, call.interruption, stops: probes.copyStops)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        Self.follow(state, with: context)
        // Made once: a copy that a stray signal ended has its file already, and fails here.
        guard try call.runOnce(source.path, { copyfile(source.path, destination.path, state, Self.copyFlags) }) == 0
        else {
            let code = errno
            if code == EEXIST { throw FileSystemError.alreadyExists(destination.path) }
            removeFailedCopy(at: destination, state)
            throw context.stopped || call.interruption.isInterrupted
                ? CocoaError(.userCancelled) : Self.posixError(code, source)
        }
        finishCopy(at: destination, of: status)
    }

    /// Takes away what a failed copy created: only the file it had open.
    private func removeFailedCopy(at destination: URL, _ state: copyfile_state_t?) {
        var descriptor: Int32 = -1
        var (created, found) = (stat(), stat())
        if copyfile_state_get(state, UInt32(COPYFILE_STATE_DST_FD), &descriptor) == 0, descriptor >= 0,
            fstat(descriptor, &created) == 0,
            lstat(destination.path, &found) == 0, found.st_dev == created.st_dev, found.st_ino == created.st_ino
        {
            if probes.system("unlink", destination.path, { unlink(destination.path) }) != 0, errno == EPERM,
                lchflags(destination.path, found.st_flags & ~Self.lockFlags) == 0
            {
                unlink(destination.path)
            }
        }
    }

    /// Gives the copy at `destination` the creation date of its source (as `source` describes it),
    /// and remembers it when it came out locked.
    private func finishCopy(at destination: URL, of source: stat) {
        var copied = stat()
        guard probes.system("lstat", destination.path, { lstat(destination.path, &copied) }) == 0 else {
            return
        }
        // A clone keeps the creation date by itself; a block copy to another volume does not.
        // (A locked copy cannot be changed any more, and is unlocked for the moment.)
        if copied.st_birthtimespec.tv_sec != source.st_birthtimespec.tv_sec {
            let isLocked = copied.st_flags & Self.lockFlags != 0
            if isLocked { lchflags(destination.path, copied.st_flags & ~Self.lockFlags) }
            setCreationDate(source.st_birthtimespec, of: destination.path)
            if isLocked { lchflags(destination.path, copied.st_flags) }
        }
        // The lock of the source came along. The copy is remembered, so that it can still
        // be renamed or removed by whoever asked for it.
        if copied.st_flags & Self.lockFlags != 0 { rememberLockedCopy(destination, copied) }
    }
}
