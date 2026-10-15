import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The output of a tool read as a stream, after the stream was closed.
@Suite
internal struct CovSmallArchiveStreamTests {
    /// Whether reading `stream` throws as a stopped stream does.
    private static func readIsStopped(_ stream: ProcessStream) -> Bool {
        do {
            _ = try stream.read(upToCount: 10)
            return false
        } catch ArchiveError.cancelled {
            return true
        } catch {
            return false
        }
    }

    /// A stream that was closed before it was read, or part-way, gives nothing more: a read
    /// throws instead of reaching into the closed pipe (it raised an exception and ended the
    /// program).
    @Test
    internal func aClosedToolStreamCannotBeRead() throws {
        let unread = try ProcessStream("/bin/echo", ["out"])
        unread.close()
        #expect(Self.readIsStopped(unread))
        let partly = try ProcessStream("/usr/bin/yes", [])
        #expect(try partly.read(upToCount: 4)?.isEmpty == false)
        partly.close()
        #expect(Self.readIsStopped(partly))
        // Closing twice is closing once.
        partly.close()
        #expect(Self.readIsStopped(partly))
    }
}
