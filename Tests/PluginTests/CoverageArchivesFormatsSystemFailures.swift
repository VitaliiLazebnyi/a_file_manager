import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// What the archive formats do when the system fails them where no file can be made to fail:
/// each test runs in a process of its own, which closes a descriptor behind its owner's back.
@Suite
internal struct CoverageArchivesFormatsSystemFailures {
    /// Closes the descriptor this process holds open for `url`; what its owner does with it
    /// afterwards fails as after an error of the disk. Only in a process of its own (an exit
    /// test), where no other thread can be given the number meanwhile.
    private static func pullDescriptor(of url: URL) -> Bool {
        let wanted = Durable.realFile(url).path
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETPATH, &buffer) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            if String(bytes: bytes, encoding: .utf8) == wanted {
                return close(descriptor) == 0
            }
        }
        return false
    }

    /// Makes a new file in the temporary folder, pulls its descriptor and ends the process with
    /// success when `close` reports the error the disk would.
    private static func closeFails(_ close: (OutputFile) throws -> Void) -> Never {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("afm-exit-\(UUID().uuidString)")
        defer { unlink(url.path) }
        guard let output = try? OutputFile(creating: url), pullDescriptor(of: url) else {
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
            Self.closeFails { try $0.close() }
        }
    }
}
