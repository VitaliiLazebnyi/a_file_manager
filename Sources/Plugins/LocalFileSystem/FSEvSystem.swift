import CoreServices
import Darwin
import Foundation

/// What the directory watcher asks of the system: a stream for one folder, and how many
/// descriptors the process has to spare. The system's answers by default; tests give their own.
///
/// **Why one folder per stream, and why the checks before a stream is made.** When
/// `FSEventStreamCreate` fails part-way, its clean-up closes descriptor 0, which the stream never
/// owned (measured on macOS 27.0.1, see `documentation/fsevents-descriptor-zero.md`). The clean-up
/// closes one descriptor for every folder of the request that it had not set up yet, and those
/// slots are still 0. It fails part-way in two cases:
///
/// - a folder whose path does not fit in `PATH_MAX` bytes as the file system spells it (one
///   such folder is enough);
/// - the process runs out of descriptors while the stream opens the folders and their parents,
///   which only closes descriptor 0 when the request has more than one folder.
///
/// Descriptor 0 is the standard input, or whatever was opened after it was closed: a socket, a
/// pipe, a file being written. The next failure closes that one under its owner. So the watcher
/// never asks for a path that does not fit, asks for one folder per stream, and leaves a
/// reserve of descriptors to the rest of the program. Should the system still fail in a way not
/// known here, descriptor 0 is given back to `/dev/null` (see `FSEvDescriptors.fillZero`).
struct FSEvSystem: Sendable {
    /// Makes a stream (not started) of the reports about `folder`, with the stream's own
    /// reference to the state in `context`; nil when the system makes none.
    let makeStream:
        @Sendable (_ folder: String, _ context: UnsafeMutablePointer<FSEventStreamContext>, FSEventStreamCallback) ->
            FSEventStreamRef?
    /// How many more descriptors the process may open.
    let spareDescriptors: @Sendable () -> Int

    /// The system's FSEvents and the process's own descriptor limit.
    static let live = Self(
        makeStream: { folder, context, callback in
            FSEventStreamCreate(
                nil,
                callback,
                context,
                [folder] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5,
                UInt32(kFSEventStreamCreateFlagWatchRoot)
            )
        },
        spareDescriptors: { FSEvDescriptors.spare() }
    )
}

/// The descriptors of the process, as far as the watcher is concerned.
enum FSEvDescriptors {
    /// Descriptors the watcher leaves to the rest of the program: a program started by the
    /// system has only 256, and a copy or a listing that finds none free fails.
    static let reserve = 64

    /// What a running stream of `folder` (a real path) holds: one descriptor for the folder and
    /// each of its parents (the stream watches them for a rename of the folder), and a few of
    /// its own. Measured: 3 for `/`, 6 for `/private/tmp`, 71 for a folder 67 levels down.
    static func cost(of folder: String) -> Int {
        folder.split(separator: "/").count + 4
    }

    /// Whether the system can take `folder` as a path: it must fit, as the file system spells
    /// it (decomposed), in `PATH_MAX` bytes with its closing zero.
    static func fits(_ folder: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return CFStringGetFileSystemRepresentation(folder as CFString, &buffer, buffer.count)
    }

    /// How many more descriptors the process may open now.
    static func spare() -> Int {
        var limit = rlimit()
        // (Asking for a limit that exists does not fail.)
        getrlimit(RLIMIT_NOFILE, &limit)
        return Int(clamping: limit.rlim_cur) - openCount()
    }

    /// The descriptors open in the process now.
    static func openCount() -> Int {
        let size = MemoryLayout<proc_fdinfo>.stride
        // The first answer is a size with room to spare; the second the descriptors themselves.
        let room = max(Int(proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)), 0) / size + 1
        var list = [proc_fdinfo](repeating: proc_fdinfo(), count: room)
        let filled = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &list, Int32(room * size))
        return max(Int(filled), 0) / size
    }

    /// Puts `/dev/null` on descriptor 0 if it is free, after the system failed to make a stream.
    ///
    /// Safe whatever the other threads do: `open` takes the lowest free descriptor, so the new
    /// one lands on 0 only when 0 is free, and nobody's descriptor is ever replaced. When 0 is
    /// taken (as it normally is, or because another thread opened something meanwhile), the
    /// new one lands elsewhere and is closed again. Returns whether 0 was filled.
    @discardableResult
    static func fillZero() -> Bool {
        let descriptor = open("/dev/null", O_RDWR)
        if descriptor > 0 { close(descriptor) }
        return descriptor == 0
    }
}
