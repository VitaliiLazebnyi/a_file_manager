import AFMKernel
import Foundation
import Testing

@testable import ArchivesPlugin

/// Reading a member through `ArchiveMemberReader`: opened again after it was closed, read
/// past its end, and given up while it was being opened.
@Suite
internal struct CoverageArchivesFSMemberReaderTests {
    /// A member's bytes in memory, read front to back, that knows whether it was closed.
    private final class MemberBytes: ByteStream {
        private let bytes: Data
        private var position = 0
        private(set) var isClosed = false

        init(_ text: String) {
            bytes = Data(text.utf8)
        }

        func read(upToCount count: Int) -> Data? {
            guard position < bytes.count else {
                return nil
            }
            let end = min(bytes.count, position + count)
            defer { position = end }
            return bytes.subdata(in: position..<end)
        }

        func close() {
            isClosed = true
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The streams a reader opened, in order.
    private final class Openings {
        var streams: [MemberBytes] = []

        func open(_ text: String) -> MemberBytes {
            let stream = MemberBytes(text)
            streams.append(stream)
            return stream
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A read or a seek after `close()` opens the member again from its start.
    @Test
    internal func aClosedReaderOpensTheMemberAgain() throws {
        let openings = Openings()
        let reader = try ArchiveMemberReader(cancellation: nil) { _ in openings.open("member text") }
        #expect(try reader.read(upToCount: 6) == Data("member".utf8))
        reader.close()
        #expect(openings.streams.count == 1 && openings.streams[0].isClosed)
        #expect(try reader.read(upToCount: 6) == Data("member".utf8))
        #expect(openings.streams.count == 2)
        reader.close()
        // A seek after the close opens it again too, and reads up to the place.
        try reader.seek(to: 7)
        let rest = try reader.read(upToCount: 100)
        #expect(openings.streams.count == 3 && rest == Data("text".utf8))
    }

    /// A seek past the end of a member that is read front to back stops at the end.
    @Test
    internal func aSeekPastTheEndStopsAtTheEnd() throws {
        let reader = try ArchiveMemberReader(cancellation: nil) { _ in MemberBytes("short") }
        try reader.seek(to: 1_000)
        #expect(try reader.read(upToCount: 10) == nil)
    }

    /// A cancellation while the member is being opened ends the opening, and the stream that
    /// was opened all the same is closed.
    @Test
    internal func aCancellationDuringTheOpeningClosesTheStream() {
        let flag = CancellationFlag()
        let openings = Openings()
        #expect(throws: ArchiveError.self) {
            _ = try ArchiveMemberReader(cancellation: flag) { _ in
                flag.cancel()
                return openings.open("never read")
            }
        }
        #expect(openings.streams.count == 1 && openings.streams[0].isClosed)
    }
}
