import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// What the archive formats do when the system fails them where no file can be made to fail:
/// each test runs in a process of its own, which closes a descriptor behind its owner's back.
@Suite
internal struct CoverageArchivesFormatsSystemFailures {
    /// Closes the descriptor this process holds open for `url`; what its owner does with it
    /// afterwards fails as after an error of the disk.
    ///
    /// Only in a process of its own (an exit test), where no other thread can be given the number
    /// meanwhile.
    private static func pullDescriptor(of url: URL) -> Bool {
        let wanted = Durable.realFile(url).path
        return pullDescriptor { $0 == wanted }
    }

    /// Closes the first descriptor whose path `matches` says yes to; see `pullDescriptor(of:)`.
    private static func pullDescriptor(where matches: (String) -> Bool) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETPATH, &buffer) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            if let path = String(bytes: bytes, encoding: .utf8), matches(path) {
                return close(descriptor) == 0
            }
        }
        return false
    }

    /// Ends the process with success when `body` says so, with failure when it says no or throws.
    private static func exitWith(_ body: () throws -> Bool) -> Never {
        exit((try? body()) == true ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    /// A new, empty folder in the temporary folder, held open to unpack into.
    private static func unpackFolder() throws -> UnpackFolder {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("afm-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try UnpackFolder(url)
    }

    /// Writes `file.txt` into `folder`, pulling the descriptor of its temporary file first;
    /// `puts` says whether anything is then written through it.
    ///
    /// The text of the error.
    private static func failedWrite(into folder: UnpackFolder, puts: Bool) -> String? {
        CoverageArchivesFormatsSupport.failure {
            let file = UnpackFolder.NewFile(
                names: ["file.txt"],
                replacing: false,
                permissions: 0o644,
                modified: Date(),
                quarantine: nil
            )
            return try folder.write(file, opened: nil) { put in
                guard pullDescriptor(where: { $0.contains("/.afm-") }) else {
                    return
                }
                if puts {
                    try put(Data("x".utf8))
                }
            }
        }
    }

    /// Makes a new file in the temporary folder, pulls its descriptor and ends the process with
    /// success when `close` reports the error the disk would.
    private static func closeFails(_ close: (OutputFile) throws -> Void) -> Never {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("afm-exit-\(UUID().uuidString)")
        defer { unlink(url.path) }
        guard let output = try? OutputFile(creating: url, mode: 0o600), pullDescriptor(of: url) else {
            exit(EXIT_FAILURE)
        }
        let message = CoverageArchivesFormatsSupport.failure { try close(output) }
        exit(message == CoverageArchivesFormatsSupport.systemError(EBADF, url.path) ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    /// A file that cannot be made durable is reported, not taken as written.
    @Test
    internal func aFileThatCannotBeMadeDurableIsReported() async {
        await #expect(processExitsWith: .success) {
            Self.closeFails { try $0.close(durably: true) }
        }
    }

    /// A file that fails to close is reported.
    @Test
    internal func aFileThatFailsToCloseIsReported() async {
        await #expect(processExitsWith: .success) {
            Self.closeFails { try $0.close(durably: false) }
        }
    }

    /// A folder that cannot be opened once more, because the process has used up its
    /// descriptors, is reported.
    @Test
    internal func aFolderThatCannotBeOpenedAgainIsReported() async {
        await #expect(processExitsWith: .success) {
            Self.exitWith {
                let folder = try Self.unpackFolder()
                var limit = rlimit()
                getrlimit(RLIMIT_NOFILE, &limit)
                limit.rlim_cur = 64
                setrlimit(RLIMIT_NOFILE, &limit)
                while open("/dev/null", O_RDONLY) >= 0 {
                    // Takes the next free number.
                }
                let message = CoverageArchivesFormatsSupport.failure { try folder.makeFolder(["sub"], quarantine: nil) }
                return message == CoverageArchivesFormatsSupport.systemError(EMFILE, folder.url.path)
            }
        }
    }

    /// A member whose data the disk does not take is reported, and nothing of it stays.
    @Test
    internal func aMemberTheDiskDoesNotTakeIsReported() async {
        await #expect(processExitsWith: .success) {
            Self.exitWith {
                let folder = try Self.unpackFolder()
                let message = Self.failedWrite(into: folder, puts: true)
                let place = folder.url.path + "/file.txt"
                let left = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
                return message == CoverageArchivesFormatsSupport.systemError(EBADF, place) && left.isEmpty
            }
        }
    }

    /// A member whose rights the disk does not take is reported, and nothing of it stays.
    @Test
    internal func aMemberWhoseRightsTheDiskRefusesIsReported() async {
        await #expect(processExitsWith: .success) {
            Self.exitWith {
                let folder = try Self.unpackFolder()
                let message = Self.failedWrite(into: folder, puts: false)
                let place = folder.url.path + "/file.txt"
                let left = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
                return message == CoverageArchivesFormatsSupport.systemError(EBADF, place) && left.isEmpty
            }
        }
    }
}
