import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The compressors and decompressors, and the system's tools behind them.
@Suite
internal struct CoverageArchivesFormatsCodecs {
    private typealias Support = CoverageArchivesFormatsSupport

    private let box: Sandbox

    /// A new folder for each test.
    internal init() throws {
        box = try Sandbox()
    }

    private func deflated(_ text: String) throws -> Data {
        try Deflater.piece(Data(text.utf8), level: 6, final: true, calls: .zlib)
    }

    /// Deflate data that is cut off ends too early.
    @Test
    internal func deflateDataThatIsCutOffEndsTooEarly() throws {
        let whole = try deflated(String(repeating: "cut off in the middle ", count: 200))
        let stream = InflateStream(DataStream(whole.prefix(whole.count / 2)), wrapping: .raw, control: nil)
        #expect(
            Support.failure { _ = try stream.readFully(1 << 20) }
                == ArchiveError.damaged("the compressed data ends too early").errorDescription
        )
    }

    /// Deflate data comes in blocks no larger than asked for, and a request for nothing gets nothing.
    @Test
    internal func deflateDataComesInBlocksOfTheSizeAskedFor() throws {
        let text = String(repeating: "a large block of text ", count: 100_000)
        let stream = InflateStream(DataStream(try deflated(text)), wrapping: .raw, control: nil)
        var data = Data()
        while let block = try stream.read(upToCount: 1 << 20) {
            #expect(block.count <= 1 << 20)
            data.append(block)
        }
        #expect(data == Data(text.utf8))
        #expect(try stream.read(upToCount: 0) == nil)
    }

    /// An XZ file of nothing is a valid file that holds nothing.
    @Test
    internal func anEmptyXZFileHoldsNothing() throws {
        let empty = try XZCoder.compress(Data())
        #expect(!empty.isEmpty)
        let stream = try XZStream(DataStream(empty), control: nil)
        #expect(try stream.read(upToCount: 100) == nil)
    }

    /// XZ data that cannot be decoded, and XZ data that is cut off, are damage, each with its reason.
    @Test
    internal func xzDataThatCannotBeDecodedOrIsCutOffIsDamage() throws {
        let magic = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
        let garbage = try XZStream(DataStream(magic + Data(repeating: 0x55, count: 64)), control: nil)
        #expect(
            Support.failure { _ = try garbage.readFully(100) }
                == ArchiveError.damaged("the LZMA data cannot be decoded").errorDescription
        )
        var random = Data(count: 50_000)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let whole = try XZCoder.compress(random)
        let cut = try XZStream(DataStream(whole.prefix(whole.count - 40)), control: nil)
        #expect(
            Support.failure { _ = try cut.readFully(100_000) }
                == ArchiveError.damaged("the compressed data ends too early").errorDescription
        )
    }

    /// A filter gives what the tool writes, nothing included, and reports a tool that fails.
    @Test
    internal func aFilterGivesWhatTheToolWritesAndReportsAToolThatFails() throws {
        let nothing = try Tool.filter("/bin/cat", [], input: Data())
        #expect(nothing.isEmpty)
        #expect(try Tool.filter("/bin/cat", [], input: Data("same".utf8)) == Data("same".utf8))
        #expect(Support.failure { _ = try Tool.filter("/usr/bin/false", [], input: Data()) } == "false failed.")
    }

    /// The output of a tool ends once and stays ended.
    @Test
    internal func aToolsOutputEndsOnce() throws {
        let stream = try ProcessStream("/bin/echo", ["out"], control: nil)
        #expect(try stream.readFully(100) == Data("out\n".utf8))
        #expect(try stream.read(upToCount: 10) == nil)
        #expect(try stream.read(upToCount: 10) == nil)
        stream.close()
    }

    /// A BZIP2 file that was replaced since it was opened is not handed to the tool by its path.
    @Test
    internal func aReplacedBZIP2FileIsNotHandedToTheTool() throws {
        let url = try box.file("data.bz2", "not really bzip2")
        let file = try RandomAccessFile(url, shownAs: nil)
        try FileManager.default.removeItem(at: url)
        try box.file("data.bz2", "another file under the same name")
        #expect(
            Support.failure { _ = try ArchiveFormat.Codec.bzip2.decompressing(file, control: nil) }
                == ArchiveError.changedOutside("data.bz2").errorDescription
        )
    }

    /// A GZIP file too short to be one claims no size.
    @Test
    internal func aGZIPFileTooShortClaimsNoSize() throws {
        let file = try RandomAccessFile(try box.file("short.gz", "tiny"), shownAs: nil)
        #expect(CompressedSize.claimedByGzip(file) == nil)
    }

    // MARK: Compressing on all cores

    /// Writes `count` zero bytes in one block through the compressor; returns the file.
    private func compressed(_ method: ParallelCompressor.Method, count: Int) throws -> URL {
        let url = box.url("\(UUID().uuidString).out")
        let output = try OutputFile(creating: url, mode: 0o600)
        let compressor = try ParallelCompressor(method, to: output, modified: Date())
        try compressor.write(Data(count: count))
        try compressor.finish()
        try output.close(durably: false)
        return url
    }

    private func zeros(in stream: any ByteStream) throws -> Int {
        var count = 0
        while let block = try stream.read(upToCount: 1 << 20) {
            #expect(!block.contains { $0 != 0 })
            count += block.count
        }
        return count
    }

    /// Data that fills whole windows ends a valid file: the end adds only what the format needs.
    @Test
    internal func dataThatFillsWholeWindowsEndsAValidFile() throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // Exactly one window each: everything is written before the end, which then adds
        // deflate's end block, and nothing for XZ.
        let gzipCount = (1 << 20) * cores
        let gzip = try RandomAccessFile(try compressed(.gzip(level: 1), count: gzipCount), shownAs: nil)
        #expect(
            try zeros(in: InflateStream(FileRangeStream(gzip, offset: 0, length: nil), wrapping: .gzip, control: nil))
                == gzipCount
        )
        let xzCount = (8 << 20) * min(cores, 4)
        let lzma = try RandomAccessFile(try compressed(.xz, count: xzCount), shownAs: nil)
        #expect(try zeros(in: XZStream(FileRangeStream(lzma, offset: 0, length: nil), control: nil)) == xzCount)
        #expect(CompressedSize.ofXZ(lzma) == UInt64(xzCount))
    }
}
