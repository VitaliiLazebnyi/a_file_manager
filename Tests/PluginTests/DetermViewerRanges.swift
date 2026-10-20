import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// A source asked for nothing: the reads that fall outside the file.
@Suite
internal struct DetermViewerRanges {
    /// Counts what the viewer asks of it.
    private final class CountingSource: ByteSource, @unchecked Sendable {
        // Read and written only by the test's own thread.
        var reads = 0
        let length: Int64 = 10

        func read(at offset: Int64, count: Int) -> Data {
            reads += 1
            return Data(repeating: 0x61, count: min(count, Int(length - offset)))
        }

        deinit {
            // Nothing to release.
        }
    }

    /// An empty range, and one behind the end of the file, give no bytes without a read.
    @Test
    internal func aRangeOutsideTheFileGivesNothingWithoutAskingTheSource() throws {
        let source = CountingSource()
        #expect(try source.read(4..<4).isEmpty)
        #expect(try source.read(10..<20).isEmpty)
        #expect(try source.read(30..<40, cancellation: CancellationFlag()).isEmpty)
        #expect(source.reads == 0)
        // Half inside: the inside half.
        #expect(try source.read(8..<20) == Data([0x61, 0x61]) && source.reads == 1)
    }
}
