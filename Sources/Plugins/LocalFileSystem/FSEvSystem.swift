import CoreServices
import Foundation

/// What the directory watcher asks of the system: a stream for one folder, and how many
/// descriptors the process has to spare. The system's answers by default; tests give their own.
///
/// **Why one folder per stream, and why the checks before a stream is made.** When
/// `FSEventStreamCreate` fails part-way, its clean-up closes descriptor 0, which the stream never
/// owned (measured on macOS 27.0.1, see `documentation/FSEvents-descriptor-zero.md`). The clean-up
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
internal struct FSEvSystem: Sendable {
    /// The system's FSEvents and the process's own descriptor limit.
    internal static let live = Self(
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

    /// Makes a stream (not started) of the reports about `folder`, with the stream's own
    /// reference to the state in `context`; nil when the system makes none.
    internal let makeStream:
        @Sendable (_ folder: String, _ context: UnsafeMutablePointer<FSEventStreamContext>, FSEventStreamCallback) ->
            FSEventStreamRef?
    /// How many more descriptors the process may open.
    internal let spareDescriptors: @Sendable () -> Int
}
