import Foundation
import TestSupport
import Testing
import zlib

@testable import ArchivesPlugin

/// What the deflate compressor does when zlib fails: it says so, instead of handing on a piece
/// that is cut short and would end the archive too early.
@Suite
internal struct ArcFixDeflaterTests {
    private typealias Support = CoverageArchivesFormatsSupport

    private let text = Data(String(repeating: "compressed when zlib lets it ", count: 1_000).utf8)

    /// The text of the error zlib's `status` is reported with.
    private func failure(_ status: Int32) -> String? {
        ArchiveError.toolFailed("The data could not be compressed (zlib error \(status)).").errorDescription
    }

    /// A compressor zlib refuses to start (here because it is told of a stream of the wrong
    /// size, as it would be for one of another version) fails, and gives zlib's reason.
    @Test
    internal func aCompressorThatCannotStartFails() {
        let calls = DeflateCalls(
            start: { stream, level in
                deflateInit2_(stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, 0)
            },
            run: DeflateCalls.zlib.run
        )
        #expect(Support.failure { _ = try Deflater.piece(text, level: 6, final: true, calls: calls) } == failure(-6))
    }

    /// A stream zlib finds in a state it does not accept (here a flush mode it does not know)
    /// fails, for a last piece and for one in the middle.
    @Test(arguments: [true, false])
    internal func aStreamThatZlibRefusesFails(final: Bool) {
        let calls = DeflateCalls(start: DeflateCalls.zlib.start) { stream, _ in deflate(stream, 99) }
        #expect(
            Support.failure { _ = try Deflater.piece(text, level: 6, final: final, calls: calls) }
                == failure(Z_STREAM_ERROR)
        )
    }

    /// Pieces made by zlib itself join into one stream that unpacks to what went in, the empty
    /// last piece too.
    @Test
    internal func piecesJoinIntoOneStream() throws {
        let joined =
            try Deflater.piece(text, level: 1, final: false) + Deflater.piece(text, level: 12, final: false)
            + Deflater.piece(Data(), level: 0, final: true)
        #expect(try InflateStream(DataStream(joined), wrapping: .raw).readFully(1 << 20) == text + text)
    }
}
