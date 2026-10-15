import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Local file systems that stand in for the system where a test needs it to fail or to be asked, and what the tests
/// read back from the disk.
internal enum CoverageLocalProbes {
    /// A local file system whose system calls of `name` about paths that end in `suffix` fail with `code`, from the
    /// `after`-th such call on (counted from 0); every other call is made.
    internal static func failing(
        _ name: String,
        endingIn suffix: String,
        _ code: Int32,
        after: Int
    ) -> LocalFileSystem {
        let calls = Shared(0)
        var probes = LocalProbes()
        probes.fault = { call, path in
            guard call == name, path.hasSuffix(suffix) else {
                return nil
            }
            var count = 0
            calls.modify { total in
                count = total
                total += 1
            }
            return count >= after ? code : nil
        }
        return LocalFileSystem(probes: probes)
    }

    /// The same, failing from the first call on.
    internal static func failing(_ name: String, endingIn suffix: String, _ code: Int32) -> LocalFileSystem {
        failing(name, endingIn: suffix, code, after: 0)
    }

    /// A local file system whose `willAsk` calls `action` with the path and how often it was asked about before.
    internal static func asking(_ action: @escaping @Sendable (String, Int) -> Void) -> LocalFileSystem {
        let counts = Shared<[String: Int]>([:])
        var probes = LocalProbes()
        probes.willAsk = { path in
            var count = 0
            counts.modify { table in
                count = table[path, default: 0]
                table[path] = count + 1
            }
            action(path, count)
        }
        return LocalFileSystem(probes: probes)
    }

    /// A local file system whose figures of free space are those `figures` gives.
    internal static func spaced(
        _ figures: @escaping @Sendable (String) -> (available: Int64?, important: Int64?)
    ) -> LocalFileSystem {
        var probes = LocalProbes()
        probes.freeSpace = figures
        return LocalFileSystem(probes: probes)
    }

    /// Where the volume of `url` is mounted, and which volume it is.
    internal static func mount(of url: URL) -> (path: String, volume: fsid_t) {
        var info = statfs()
        statfs(url.path, &info)
        let path = withUnsafeBytes(of: &info.f_mntonname) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? "/"
        }
        return (path, info.f_fsid)
    }

    /// The code of a POSIX error, as the local file system throws them; -1 for any other error.
    internal static func code(_ error: any Error) -> Int {
        let posix = error as NSError
        return posix.domain == NSPOSIXErrorDomain ? posix.code : -1
    }

    /// The flags of an item itself (a link is not followed).
    internal static func flags(_ url: URL) -> UInt32 {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_flags : 0
    }

    /// Whether the item itself carries the lock of the Finder.
    internal static func isLocked(_ url: URL) -> Bool {
        flags(url) & UInt32(UF_IMMUTABLE) != 0
    }

    /// A locked file `source.txt` and the copy `copy` of it the file system made in `folder`, which it remembers as
    /// its own to rename or remove.
    internal static func lockedCopy(in box: Sandbox, folder: String, named copy: String, _ local: LocalFileSystem)
        throws -> URL
    {
        let source = try box.file("source.txt", "locked")
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(source.path, 0) }
        let target = box.url(folder.isEmpty ? copy : folder + "/" + copy)
        try local.copy(source, to: target) { _ in true }
        #expect(CoverageLocalProbes.isLocked(target))
        return target
    }

    /// The same in the sandbox itself.
    internal static func lockedCopy(in box: Sandbox, named copy: String, _ local: LocalFileSystem) throws -> URL {
        try lockedCopy(in: box, folder: "", named: copy, local)
    }
}
