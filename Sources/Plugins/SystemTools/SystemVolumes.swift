import AFMKernel
import AppKit
import Darwin

/// The volumes of this Mac, ejected by `unmount`: the system's, or a stand-in that ejects nothing.
internal final class SystemVolumes: VolumeAccess {
    /// Unmounts a volume and then calls back, on a queue of its own, with what went wrong, if anything.
    internal typealias Unmount =
        @Sendable (URL, FileManager.UnmountOptions, @escaping @Sendable ((any Error)?) -> Void) -> Void

    /// The system's.
    internal static let unmount: Unmount = { volume, options, completion in
        FileManager.default.unmountVolume(at: volume, options: options, completionHandler: completion)
    }

    private let unmountVolume: Unmount

    /// Volumes that `unmount` ejects.
    internal init(unmount: @escaping Unmount) {
        unmountVolume = unmount
    }

    /// The name the user knows a program by: the application's, else the process's.
    internal static func programName(_ pid: pid_t) -> String? {
        guard pid > 0 else {
            return nil
        }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }
        return SystemText.string(buffer)
    }

    /// What the volume of `directory` tells about itself; facts with no volume when it does not
    /// answer.
    ///
    /// Asks the disk: for a job's thread.
    internal func facts(of directory: URL) -> VolumeFacts {
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey,
            .volumeIsLocalKey, .volumeIsRootFileSystemKey
        ]
        // Every mounted volume has a name.
        guard let values = try? directory.resourceValues(forKeys: keys), let url = values.volume,
            let name = values.volumeName
        else {
            return VolumeFacts()
        }
        let canBeEjected = Place.VolumeTraits(path: url.path, values: values).mayBeEjected
        return VolumeFacts(url: url, name: name, canBeEjected: canBeEjected, isNetwork: values.volumeIsLocal == false)
    }

    /// Unmounts `volume` (a disk with all its volumes, so that it can be taken out) and waits
    /// for the answer: nil when it went, else who refused.
    ///
    /// Blocks: for a job's thread.
    internal func eject(_ volume: VolumeFacts) -> EjectRefusal? {
        guard let url = volume.url else {
            return EjectRefusal(reason: "The volume is not known.")
        }
        // Never forced: a drive something still writes to is refused, not cut off. A disk
        // goes as a whole, with its other volumes, so that it can be taken out.
        let options: FileManager.UnmountOptions = volume.isNetwork ? [] : [.allPartitionsAndEjectDisk]
        let done = DispatchSemaphore(value: 0)
        // Set by the callback before `done` is signalled, and read only after the wait.
        nonisolated(unsafe) var failure: (any Error)?
        unmountVolume(url, options) { error in
            failure = error
            done.signal()
        }
        done.wait()
        guard let failure else {
            return nil
        }
        let error = failure as NSError
        let dissenter = error.userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? pid_t
        return EjectRefusal(
            reason: error.localizedDescription,
            program: dissenter.flatMap(Self.programName),
            isThisProgram: dissenter == getpid()
        )
    }

    deinit {
        // Nothing to release.
    }
}
