import CoreServices
import Darwin
import Foundation

/// The descriptors of the process, as far as the directory watcher is concerned (see
/// `FSEvSystem` for why it counts them).
internal enum FSEvDescriptors {
    /// Descriptors the watcher leaves to the rest of the program: a program started by the
    /// system has only 256, and a copy or a listing that finds none free fails.
    internal static let reserve = 64

    /// What a running stream of `folder` (a real path) holds: one descriptor for the folder and
    /// each of its parents (the stream watches them for a rename of the folder), and a few of
    /// its own.
    ///
    /// Measured: 3 for `/`, 6 for `/private/tmp`, 71 for a folder 67 levels down.
    internal static func cost(of folder: String) -> Int {
        folder.split(separator: "/").count + 4
    }

    /// Whether the system can take `folder` as a path: it must fit, as the file system spells
    /// it (decomposed), in `PATH_MAX` bytes with its closing zero.
    internal static func fits(_ folder: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return CFStringGetFileSystemRepresentation(folder as CFString, &buffer, buffer.count)
    }

    /// How many more descriptors the process may open now.
    internal static func spare() -> Int {
        var limit = rlimit()
        // (Asking for a limit that exists does not fail.)
        getrlimit(RLIMIT_NOFILE, &limit)
        return Int(clamping: limit.rlim_cur) - openCount()
    }

    /// The descriptors open in the process now.
    internal static func openCount() -> Int {
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
    internal static func fillZero() -> Bool {
        let descriptor = open("/dev/null", O_RDWR)
        if descriptor > 0 { close(descriptor) }
        return descriptor == 0
    }
}
