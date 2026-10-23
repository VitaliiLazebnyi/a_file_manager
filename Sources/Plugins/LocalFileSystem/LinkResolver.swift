import AFMKernel
import Foundation

/// Finds out where links lead without letting a link into a share that does not answer hold
/// up a listing.
///
/// A target on a disk of this Mac is asked for at once; one anywhere else is asked for on a thread
/// of its own and waited for for a moment only. A few such questions may be stuck for good (each
/// holds a thread until the share answers); past that limit links into places that are not local
/// are no longer followed. All state is guarded by `lock`.
internal final class LinkResolver: @unchecked Sendable {
    /// Where the thread that asks leaves the answer for the caller who may have stopped waiting.
    ///
    /// All state is guarded by `lock`.
    private final class Answer: @unchecked Sendable {
        /// Guards `target`.
        let lock = NSLock()
        /// What the system said; nil until it has said it, or when nothing is there.
        var target: LinkTarget?

        deinit {
            // Nothing to release.
        }
    }

    /// The resolver of the program, which asks the system.
    internal static let shared = LinkResolver()
    /// How many questions into places that are not disks of this Mac may be under way at once.
    internal static let limit = 8

    private let lock = NSLock()
    private var inFlight = 0
    private let patience: TimeInterval
    /// Asks the system where a link leads (`stat`); it may wait for as long as the volume does.
    private let lookup: @Sendable (String) -> LinkTarget?

    /// Asks the system, and waits a moment and a half for a place that is not a disk of this Mac.
    internal convenience init() {
        self.init(patience: 1.5, lookup: Self.lookup)
    }

    /// `lookup` and `patience` stand in for the system and its moment when a test makes a share
    /// that does not answer.
    internal init(patience: TimeInterval, lookup: @escaping @Sendable (String) -> LinkTarget?) {
        (self.patience, self.lookup) = (patience, lookup)
    }

    /// What the link at `path` leads to, as the system says (`stat`); nil when nothing is there.
    internal static func lookup(_ path: String) -> LinkTarget? {
        var status = stat()
        guard stat(path, &status) == 0 else {
            return nil
        }
        let type = status.st_mode & S_IFMT
        return LinkTarget(
            isDirectory: type == S_IFDIR,
            isRegular: type == S_IFREG,
            size: type == S_IFREG ? Int64(status.st_size) : 0
        )
    }

    /// Where the link says it points, as an absolute path, worked out from the text of the
    /// link alone (the target is not looked at).
    ///
    /// Nil when the link cannot be read.
    private static func absoluteTarget(of path: String) -> String? {
        let text: String? = withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(PATH_MAX) + 1) { buffer in
            let length = readlink(path, buffer.baseAddress, Int(PATH_MAX))
            guard length > 0 else {
                return nil
            }
            buffer[length] = 0
            return buffer.baseAddress.flatMap { start in String(validatingCString: start) }
        }
        guard let text else {
            return nil
        }
        var absolute = text
        // By bytes, as the file system reads a path: a `/` with a combining mark after it is
        // one character that is not `/`, and a cut by characters would not see it.
        if text.utf8.first != 0x2F {
            // The folder of the link: everything before its last `/` (nothing for a bare name).
            let directory = path.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
                .dropLast()
                .map { name in String(Substring(name)) }
                .joined(separator: "/")
            absolute = directory + "/" + text
        }
        var parts: [Substring.UTF8View] = []
        for part in absolute.utf8.split(separator: 0x2F) {
            if part.elementsEqual([0x2E]) { continue }
            if part.elementsEqual([0x2E, 0x2E]) { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.map { part in String(Substring(part)) }.joined(separator: "/")
    }

    /// Nil when the target does not exist (a dangling link) or did not answer in time.
    internal func resolve(_ path: String) -> LinkTarget? {
        if let target = Self.absoluteTarget(of: path), MountTable.shared.isLocal(target) {
            return lookup(path)
        }
        lock.lock()
        guard inFlight < Self.limit else {
            lock.unlock()
            return nil
        }
        inFlight += 1
        lock.unlock()
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        // A thread of the kernel's own: one that never comes back is not one of a dispatch queue's few.
        let ask = lookup
        BlockingCalls.run {
            let target = ask(path)
            answer.lock.lock()
            answer.target = target
            answer.lock.unlock()
            self.lock.lock()
            self.inFlight -= 1
            self.lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + patience) == .success else {
            return nil
        }
        answer.lock.lock()
        defer { answer.lock.unlock() }
        return answer.target
    }

    deinit {
        // Nothing to release: a question still under way holds what it needs itself.
    }
}
