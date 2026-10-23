public import AFMKernel
public import Foundation
import NetFS

/// The real thing: the NetFS framework, which is what Finder's Connect to Server uses.
public final class SystemVolumeMounter: VolumeMounter {
    /// The system's calls, which answer later or never; tests put stand-ins in their place.
    internal struct Calls {
        /// `NetFSMountURLAsync`: asks for the mount without waiting.
        ///
        /// Returns the status of asking, puts what to cancel the request with into its seventh
        /// argument, and later calls the block with the status and the mount points, on the queue
        /// it is given.
        internal var mount:
            @Sendable (
                _ url: CFURL?, _ mountPath: CFURL?, _ user: CFString?, _ password: CFString?,
                _ openOptions: CFMutableDictionary?, _ mountOptions: CFMutableDictionary?,
                _ request: UnsafeMutablePointer<AsyncRequestID?>?, _ queue: DispatchQueue?,
                _ report: (@Sendable @convention(block) (Int32, AsyncRequestID?, CFArray?) -> Void)?
            ) -> Int32 = NetFSMountURLAsync
        /// `NetFSMountURLCancel`.
        internal var cancel: @Sendable (_ request: AsyncRequestID?) -> Int32 = NetFSMountURLCancel
        /// `FileManager.unmountVolume(at:options:completionHandler:)` without its dialog: ejects `volume` and later
        /// calls `answer` with nil or the error, on a queue of the system's.
        internal var unmount: @Sendable (_ volume: URL, _ answer: @escaping @Sendable (any Error?) -> Void) -> Void =
            Self.unmountWithoutDialog

        /// The system's eject of `volume`, which reports to `answer` and shows no dialog of its own.
        private static func unmountWithoutDialog(_ volume: URL, answer: @escaping @Sendable (any Error?) -> Void) {
            FileManager.default.unmountVolume(at: volume, options: [.withoutUI], completionHandler: answer)
        }
    }

    /// What the system's answer is delivered into; it may come after the waiting thread left.
    ///
    /// The first answer counts; until it comes the value is an input/output error. `result`,
    /// `isSet` and `failure` are guarded by `lock`.
    private final class Outcome: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: (status: Int32, paths: [String]) = (EIO, [])
        private var isSet = false
        private var failure: (any Error)?

        var value: (status: Int32, paths: [String]) {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        var error: (any Error)? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        func set(_ status: Int32, _ paths: [String], failure error: (any Error)? = nil) {
            lock.lock()
            if !isSet { (result, failure, isSet) = ((status, paths), error, true) }
            lock.unlock()
            done.signal()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// How long ejecting may take before the wait for it is given up.
    internal static let unmountTime: TimeInterval = 60
    private let calls: Calls
    private let patience: TimeInterval

    /// A mounter that makes the system's own calls and waits a minute at most for an eject.
    public convenience init() {
        self.init(calls: Calls(), unmountTime: Self.unmountTime)
    }

    /// A mounter that makes `calls` and gives up waiting for an eject after `unmountTime` seconds.
    internal init(calls: Calls, unmountTime: TimeInterval) {
        self.calls = calls
        patience = unmountTime
    }

    private static func reason(_ status: Int32) -> String {
        status > 0 ? String(cString: strerror(status)) : "error \(status)"
    }

    /// Mounts `url` with a cancellation flag nobody sets; see `mount(_:cancellation:)`.
    public func mount(_ url: URL) throws -> [URL] {
        try mount(url, cancellation: CancellationFlag())
    }

    /// Asks NetFS to mount `url` and waits for its answer, checking `cancellation` ten times a second.
    ///
    /// Returns the mount points; throws `NetworkError.cancelled` once the flag is set (the request is taken back) and
    /// a `VolumeError` when the system cannot ask or the server refuses. Blocks the calling thread, a job's.
    public func mount(_ url: URL, cancellation: CancellationFlag) throws -> [URL] {
        // The address is shown without its password, here and in every message.
        let shown = ServerAddress.removingPassword(from: url.absoluteString)
        let outcome = Outcome()
        // Asked for without waiting, so that Cancel can take the request back; the server may never answer.
        var request: AsyncRequestID?
        // No mount path: the system picks a folder under /Volumes. No options: it shows its own
        // dialog for the name and password and may use the Keychain.
        let started = calls.mount(
            url as CFURL,
            nil,
            nil,
            nil,
            nil,
            nil,
            &request,
            DispatchQueue.global(qos: .userInitiated)
        ) { status, _, mountPoints in
            outcome.set(status, (mountPoints as? [String]) ?? [])
        }
        guard started == 0 else {
            throw VolumeError(
                message: "The server \(shown) could not be connected: \(Self.reason(started))."
            )
        }
        while outcome.done.wait(timeout: .now() + 0.1) == .timedOut {
            guard cancellation.isCancelled else { continue }
            if let request { _ = calls.cancel(request) }
            throw NetworkError.cancelled
        }
        let result = outcome.value
        guard result.status == 0 else {
            throw VolumeError(message: "The server \(shown) could not be connected: \(Self.reason(result.status)).")
        }
        return result.paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Ejects `volume` and waits for the system's answer, for `unmountTime` seconds at most.
    ///
    /// Throws a `VolumeError` when no answer comes in time, else the system's own error. Blocks the calling thread.
    public func unmount(_ volume: URL) throws {
        let outcome = Outcome()
        calls.unmount(volume) { error in outcome.set(error == nil ? 0 : EIO, [], failure: error) }
        // The system's answer may never come (a server that is gone); the job does not wait for ever.
        guard outcome.done.wait(timeout: .now() + patience) == .success else {
            let seconds = Int(patience.rounded(.up))
            let name = volume.lastPathComponent
            throw VolumeError(message: "\(name) did not answer to being ejected within \(seconds) seconds.")
        }
        if let error = outcome.error { throw error }
    }

    deinit {
        // Nothing to release.
    }
}
