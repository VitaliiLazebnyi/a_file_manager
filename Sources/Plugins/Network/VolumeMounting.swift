import AFMKernel
import Foundation
import NetFS

/// Mounting and ejecting network volumes, the Mac's form of mapping and disconnecting network
/// drives (spec 11 › Windows network functions). Both calls block and are made from a job.
public protocol VolumeMounter: AnyObject {
    /// Mounts the share at `url` (smb, afp, nfs, http/https for WebDAV) and returns where it
    /// appeared under /Volumes. The system asks for a name and password when it needs them.
    func mount(_ url: URL) throws -> [URL]
    /// `mount(_:)`, which ends early, by throwing, once `cancellation` is set.
    func mount(_ url: URL, cancellation: CancellationFlag) throws -> [URL]
    /// Ejects the volume mounted at `volume`.
    func unmount(_ volume: URL) throws
}

extension VolumeMounter {
    public func mount(_ url: URL, cancellation: CancellationFlag) throws -> [URL] {
        if cancellation.isCancelled { throw NetworkError.cancelled }
        return try mount(url)
    }
}

public struct VolumeError: LocalizedError {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The real thing: the NetFS framework, which is what Finder's Connect to Server uses.
public final class SystemVolumeMounter: VolumeMounter {
    /// The system's calls, which answer later or never; tests put stand-ins in their place.
    struct Calls {
        /// Asks for the mount without waiting. Returns the status of asking and what to cancel
        /// the request with; `answer` gets the status and the mount points, on any thread.
        var mount: (_ url: URL, _ answer: @escaping (Int32, [String]) -> Void) -> (status: Int32, request: AnyObject?) = { url, answer in
            var request: AsyncRequestID?
            // No mount path: the system picks a folder under /Volumes. No options: it shows its
            // own dialog for the name and password and may use the Keychain.
            let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, nil, nil, &request, DispatchQueue.global(qos: .userInitiated)) { status, _, mountPoints in
                answer(status, (mountPoints as? [String]) ?? [])
            }
            return (status, request.map { Request(id: $0) })
        }
        var cancel: (_ request: AnyObject) -> Void = { request in
            if let request = request as? Request { NetFSMountURLCancel(request.id) }
        }
        var unmount: (_ volume: URL, _ answer: @escaping (Error?) -> Void) -> Void = { volume, answer in
            FileManager.default.unmountVolume(at: volume, options: [.withoutUI], completionHandler: answer)
        }
    }

    /// The system's handle of a mount that was asked for.
    private final class Request {
        let id: AsyncRequestID
        init(id: AsyncRequestID) { self.id = id }
    }

    /// How long ejecting may take before the wait for it is given up.
    static let unmountTime: TimeInterval = 60
    private let calls: Calls
    private let patience: TimeInterval

    public convenience init() {
        self.init(calls: Calls(), unmountTime: SystemVolumeMounter.unmountTime)
    }

    init(calls: Calls, unmountTime: TimeInterval) {
        self.calls = calls
        patience = unmountTime
    }

    public func mount(_ url: URL) throws -> [URL] {
        try mount(url, cancellation: CancellationFlag())
    }

    /// What the system's answer is delivered into; it may come after the waiting thread left.
    private final class Outcome {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: (status: Int32, paths: [String])?

        func set(_ status: Int32, _ paths: [String]) {
            lock.lock()
            if result == nil { result = (status, paths) }
            lock.unlock()
            done.signal()
        }

        var value: (status: Int32, paths: [String])? {
            lock.lock(); defer { lock.unlock() }
            return result
        }
    }

    public func mount(_ url: URL, cancellation: CancellationFlag) throws -> [URL] {
        // The address is shown without its password, here and in every message.
        let shown = ServerAddress.removingPassword(from: url.absoluteString)
        let outcome = Outcome()
        // Asked for without waiting, so that Cancel can take the request back; the server may never answer.
        let (started, request) = calls.mount(url) { status, mountPoints in outcome.set(status, mountPoints) }
        guard started == 0 else { throw VolumeError(message: "The server \(shown) could not be connected: \(SystemVolumeMounter.reason(started)).") }
        while outcome.done.wait(timeout: .now() + 0.1) == .timedOut {
            guard cancellation.isCancelled else { continue }
            if let request { calls.cancel(request) }
            throw NetworkError.cancelled
        }
        guard let result = outcome.value, result.status == 0 else {
            throw VolumeError(message: "The server \(shown) could not be connected: \(SystemVolumeMounter.reason(outcome.value?.status ?? EIO)).")
        }
        return result.paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func reason(_ status: Int32) -> String {
        status > 0 ? String(cString: strerror(status)) : "error \(status)"
    }

    public func unmount(_ volume: URL) throws {
        let outcome = Outcome()
        var failure: Error?
        let lock = NSLock()
        calls.unmount(volume) { error in
            lock.lock()
            failure = error
            lock.unlock()
            outcome.set(error == nil ? 0 : EIO, [])
        }
        // The system's answer may never come (a server that is gone); the job does not wait for ever.
        guard outcome.done.wait(timeout: .now() + patience) == .success else {
            throw VolumeError(message: "\(volume.lastPathComponent) did not answer to being ejected within \(Int(patience.rounded(.up))) seconds.")
        }
        lock.lock()
        let error = failure
        lock.unlock()
        if let error { throw error }
    }
}

/// The schemes Connect to Server hands to the system; the others are this program's own.
public enum ServerSchemes {
    public static let mountable = ["smb", "afp", "nfs", "cifs", "http", "https", "webdav", "webdavs"]

    /// The volume a local path lies on, when it is one under /Volumes; nil for the startup disk.
    public static func mountedVolume(of url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/" + parts[2], isDirectory: true)
    }
}
