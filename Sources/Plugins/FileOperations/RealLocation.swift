import AFMContracts
import AFMKernel
import Foundation

/// A location as the file system it really lies on names it.
///
/// A file system that only shows the files of others (a branch view, a list of files) names a
/// folder by the path of the real one and answers `parent(of:)` with that real folder: the
/// same path under another scheme. Whatever is built from such a location (a target, a new
/// name) would be a second spelling of a real place, which no comparison of locations sees
/// through; so the real one is taken before anything is planned.
internal enum RealLocation {
    /// The real place behind `url`; `url` itself when it stands for nothing else.
    ///
    /// Works on the text of the locations alone, so it may be asked on the main thread.
    ///
    /// A file system that shows the files of others says so itself
    /// (`FileSystemProvider.realLocation(of:)`), and that answer is taken first. One that
    /// does not is still seen through by what its `parent(of:)` answers.
    internal static func resolve(_ url: URL, in fileSystems: FileSystemRegistry) -> URL {
        var current = fileSystems.realLocation(of: url)
        // The place a location of a file system that shows another one's files stands for; nil for any other.
        func seenThrough(_ location: URL) -> URL? {
            if !location.isFileURL, let provider = try? fileSystems.provider(for: location),
                let real = provider.parent(of: location),
                real.scheme != location.scheme, path(of: real) == path(of: location)
            {
                return real
            }
            return nil
        }
        // A view of a view is as deep as it gets; the bound keeps a confused provider from looping.
        var steps = 0
        while steps < 4, let real = seenThrough(current) {
            current = fileSystems.realLocation(of: real)
            steps += 1
        }
        return current
    }

    /// The path of a location, `..` and `.` resolved (a URL's path has no slash at its end).
    private static func path(of url: URL) -> String {
        url.standardized.path
    }

    /// True when files can be addressed below `directory` by writing its displayed path with
    /// a name after it, which is how the target field of a dialog names them.
    ///
    /// A list of files from anywhere is not such a place.
    internal static func takesNames(_ directory: URL, in fileSystems: FileSystemRegistry) -> Bool {
        if directory.isFileURL {
            return true
        }
        let typed = fileSystems.displayPath(directory)
        // Read from somewhere else: a path that only means something relative to where one
        // stands is not the name of this place.
        let probe = fileSystems.location(
            from: (typed.hasSuffix("/") ? typed : typed + "/") + "x",
            relativeTo: URL(fileURLWithPath: "/")
        )
        return probe.scheme == directory.scheme
    }
}
