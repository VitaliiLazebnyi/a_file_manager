import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Uploads over SFTP are only a success when the server has all of the file
/// (review 2: N038, N040, and the length of every upload).
@Suite(.enabled(if: FakeSFTPServer.isAvailable))
internal struct Review2NetworkSFTPUploads {
    /// Uploads `content` to `/up.bin` in blocks of 100 KB and closes the file with a modification date.
    private func upload(_ suite: NetworkFixSFTP, _ content: Data) throws {
        let writer = try suite.fileSystem.write(suite.url("/up.bin"))
        do {
            for start in stride(from: 0, to: content.count, by: 100_000) {
                try writer.write(content.subdata(in: start..<min(start + 100_000, content.count)))
            }
        } catch {
            // A refusal may show at a later write or at the closing; the closing is what counts.
            try? writer.close(attributes: FileAttributes())
            throw error
        }
        try writer.close(attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_600_000_000)))
    }

    /// A good upload arrives whole, its length is asked of the server, and its closing is waited for.
    @Test
    internal func aGoodUploadIsMeasuredAndConfirmed() throws {
        let suite = try NetworkFixSFTP()
        let content = NetworkFixSFTP.pattern(700_000)
        try upload(suite, content)
        #expect(try Data(contentsOf: suite.box.url("srv/up.bin")) == content)
        // The length was asked for (fstat), and the closing was waited for.
        let log = try String(contentsOf: suite.box.url("sftp-requests.log"), encoding: .utf8).split(separator: "\n")
        #expect(log.contains("8") && log.last == "4")
    }

    /// A closing the server refuses fails the upload; reading is not affected.
    @Test
    internal func aClosingThatFailsIsAFailedUpload() throws {
        let suite = try NetworkFixSFTP(mode: .failingClose)
        #expect(throws: (any Error).self) { try upload(suite, NetworkFixSFTP.pattern(50_000)) }
        // Reading is not affected: the closing of a handle that was only read tells nothing.
        try NetworkFixSFTP.pattern(1_000).write(to: suite.box.url("srv/r.bin"))
        let reader = try suite.fileSystem.read(suite.url("/r.bin"))
        #expect(try reader.read(upToCount: 2_000)?.count == 1_000)
        reader.close()
    }

    /// After a refused write the file on the server is cut back to the bytes that were confirmed.
    @Test
    internal func aRefusedWriteLeavesNoGapBehind() throws {
        let suite = try NetworkFixSFTP(mode: .failingWrite)
        let content = NetworkFixSFTP.pattern(900_000)
        #expect(throws: (any Error).self) { try upload(suite, content) }
        // The writes behind the refused one were on their way and were carried out. What is left
        // on the server is cut back to the first byte that was not confirmed: a true start of the file.
        let stored = suite.box.url("srv/up.bin")
        #expect(adoptWait { ((try? Data(contentsOf: stored))?.count ?? -1) == 65_536 })
        #expect(try Data(contentsOf: stored) == content.prefix(65_536))
    }

    /// A server that confirmed writes it did not keep makes the upload fail.
    @Test
    internal func aServerThatForgetsWhatItConfirmedIsNoticed() throws {
        let suite = try NetworkFixSFTP(mode: .forgetfulWrite)
        #expect(throws: NetworkError.self) { try upload(suite, NetworkFixSFTP.pattern(300_000)) }
    }
}
