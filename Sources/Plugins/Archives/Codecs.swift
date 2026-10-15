import AFMKernel
import Compression
import Foundation
import zlib

/// The checksum of ZIP and GZIP, from the system's zlib (which uses the processor's own
/// instructions for it).
enum CRC32 {
    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes -> UInt32 in
            var crc = uLong(crc)
            var offset = 0
            // zlib counts in 32 bits.
            while offset < bytes.count {
                let step = min(bytes.count - offset, 1 << 30)
                crc = crc32(crc, bytes.baseAddress!.assumingMemoryBound(to: Bytef.self) + offset, uInt(step))
                offset += step
            }
            return UInt32(truncatingIfNeeded: crc)
        }
    }

    static func of(_ data: Data) -> UInt32 { update(0, data) }

    /// The checksum of two blocks in a row from the checksums of each: lets blocks be summed
    /// on several cores.
    static func combine(_ first: UInt32, _ second: UInt32, secondLength: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: crc32_combine(uLong(first), uLong(second), secondLength))
    }
}

/// The two calls of zlib that compress: the one that starts a raw deflate stream at a level,
/// and the one that runs it with a flush mode. The system's; a test passes calls that fail as
/// zlib can fail (no memory, a stream in a state it does not accept).
struct DeflateCalls: Sendable {
    let start: @Sendable (UnsafeMutablePointer<z_stream>, Int32) -> Int32
    let run: @Sendable (UnsafeMutablePointer<z_stream>, Int32) -> Int32

    /// A raw stream, without the zlib or gzip wrapping.
    static let zlib = Self(
        start: { stream, level in
            deflateInit2_(
                stream,
                level,
                Z_DEFLATED,
                -15,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        },
        run: { stream, flush in deflate(stream, flush) }
    )
}

/// Deflate compression (ZIP method 8, GZIP) through zlib.
enum Deflater {
    /// One independent piece of a deflate stream, at level 1 (fast) … 9 (small). Pieces made
    /// this way, each on its own core, form one valid stream when written one after the other;
    /// the last one is `final`, the others end their block on a byte boundary without ending
    /// the stream. Throws when zlib fails, rather than hand on a piece that is cut short.
    static func piece(_ data: Data, level: Int, final: Bool, calls: DeflateCalls = .zlib) throws -> Data {
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer { stream.deallocate() }
        let started = calls.start(stream, Int32(max(1, min(level, 9))))
        guard started == Z_OK else { throw failure(started) }
        defer { deflateEnd(stream) }
        var output = Data()
        let capacity = max(1 << 14, min(data.count / 2 + 1_024, 1 << 20))
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { chunk.deallocate() }
        let mode = final ? Z_FINISH : Z_SYNC_FLUSH
        try data.withUnsafeBytes { bytes in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.pointee.avail_in = uInt(bytes.count)
            defer { stream.pointee.next_in = nil }
            while true {
                stream.pointee.next_out = chunk
                stream.pointee.avail_out = uInt(capacity)
                let status = calls.run(stream, mode)
                guard status != Z_STREAM_ERROR else { throw failure(status) }
                output.append(chunk, count: capacity - Int(stream.pointee.avail_out))
                if status == Z_STREAM_END { break }
                // Done when the output buffer was not filled and the input is used up.
                if stream.pointee.avail_out != 0, stream.pointee.avail_in == 0 { break }
            }
        }
        return output
    }

    private static func failure(_ status: Int32) -> ArchiveError {
        .toolFailed("The data could not be compressed (zlib error \(status)).")
    }
}

/// Decompresses deflate data from another stream: raw (ZIP members) or wrapped (GZIP files,
/// also several members in a row, as parallel compressors write them).
final class InflateStream: ByteStream {
    enum Wrapping {
        case raw, gzip
    }

    private let source: any ByteStream
    private let wrapping: Wrapping
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: InflateStream.inputSize)
    private static let inputSize = 1 << 16
    private var isFinished = false
    private var sourceEnded = false
    private let control: StreamInterrupt?

    init(_ source: any ByteStream, wrapping: Wrapping, control: StreamInterrupt? = nil) {
        self.source = source
        self.wrapping = wrapping
        self.control = control
        stream.initialize(to: z_stream())
        inflateInit2_(stream, wrapping == .raw ? -15 : 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
        input.deallocate()
    }

    private func refill() throws {
        guard stream.pointee.avail_in == 0, !sourceEnded else { return }
        guard let block = try source.read(upToCount: Self.inputSize) else {
            sourceEnded = true
            return
        }
        block.copyBytes(to: input, count: block.count)
        stream.pointee.next_in = input
        stream.pointee.avail_in = uInt(block.count)
    }

    func read(upToCount count: Int) throws -> Data? {
        guard !isFinished, count > 0 else { return nil }
        let capacity = min(count, 1 << 20)
        // Decompressed straight into the block that is handed on, which is not cleared first.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        var produced = 0
        do {
            try fill(buffer.assumingMemoryBound(to: Bytef.self), capacity: capacity, produced: &produced)
        } catch {
            buffer.deallocate()
            throw error
        }
        guard produced >= capacity / 2 else {
            // A block much smaller than its room is copied out, so the room is free at once.
            defer { buffer.deallocate() }
            return produced > 0 ? Data(bytes: buffer, count: produced) : nil
        }
        return Data(bytesNoCopy: buffer, count: produced, deallocator: .custom { pointer, _ in pointer.deallocate() })
    }

    private func fill(_ buffer: UnsafeMutablePointer<Bytef>, capacity: Int, produced: inout Int) throws {
        while produced == 0, !isFinished {
            try control?.check()
            try refill()
            stream.pointee.next_out = buffer
            stream.pointee.avail_out = uInt(capacity)
            let status = inflate(stream, Z_NO_FLUSH)
            produced = capacity - Int(stream.pointee.avail_out)
            switch status {
            case Z_OK:
                break

            case Z_STREAM_END:
                // A GZIP file may hold several members one after the other.
                try refill()
                if wrapping == .gzip, stream.pointee.avail_in > 0, stream.pointee.next_in.pointee == 0x1F {
                    inflateReset(stream)
                } else {
                    isFinished = true
                }

            case Z_BUF_ERROR:
                // There is room for output, so only input that has run out stops the decoder:
                // the source has ended (a source never hands over an empty block).
                throw ArchiveError.damaged("the compressed data ends too early")

            default:
                throw ArchiveError.damaged("the compressed data cannot be decoded")
            }
        }
    }

    func close() {
        source.close()
    }
}

/// LZMA in the `.xz` container, through the system's Compression framework.
final class XZCoder {
    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private var isOpen = false
    private let encodes: Bool
    private let algorithm: compression_algorithm

    /// An LZMA coder; a test passes an `algorithm` the system does not know, which it refuses
    /// as it would refuse to start one without memory for it.
    init(encoding: Bool, algorithm: compression_algorithm = COMPRESSION_LZMA) throws {
        encodes = encoding
        self.algorithm = algorithm
        try start()
    }

    deinit {
        if isOpen { compression_stream_destroy(stream) }
        stream.deallocate()
    }

    private func start() throws {
        if isOpen { compression_stream_destroy(stream) }
        isOpen =
            compression_stream_init(
                stream,
                encodes ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE,
                algorithm
            )
            == COMPRESSION_STATUS_OK
        guard isOpen else { throw ArchiveError.unsupported("LZMA compression") }
    }

    /// Feeds `input` through the coder. Returns what came out, how much of the input was used,
    /// and whether the compressed stream ended (after which a new one may start).
    func process(_ input: Data, finish: Bool, limit: Int = .max) throws -> (output: Data, consumed: Int, ended: Bool) {
        var output = Data()
        let capacity = 1 << 17
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { chunk.deallocate() }
        var consumed = 0
        var ended = false
        try input.withUnsafeBytes { bytes in
            // The coder wants a valid pointer even for no input.
            stream.pointee.src_ptr = UnsafePointer(chunk)
            if let base = bytes.bindMemory(to: UInt8.self).baseAddress { stream.pointee.src_ptr = base }
            stream.pointee.src_size = bytes.count
            while true {
                stream.pointee.dst_ptr = chunk
                stream.pointee.dst_size = capacity
                let status = compression_stream_process(
                    stream,
                    finish ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                )
                output.append(chunk, count: capacity - stream.pointee.dst_size)
                consumed = bytes.count - stream.pointee.src_size
                if status == COMPRESSION_STATUS_END {
                    ended = true
                    break
                }
                guard status == COMPRESSION_STATUS_OK else {
                    throw ArchiveError.damaged("the LZMA data cannot be decoded")
                }
                if output.count >= limit { break }
                if stream.pointee.dst_size != 0, stream.pointee.src_size == 0 { break }
            }
        }
        return (output, consumed, ended)
    }

    func restart() throws {
        try start()
    }

    static func compress(_ data: Data) throws -> Data {
        try XZCoder(encoding: true).process(data, finish: true).output
    }
}

/// Decompresses an `.xz` file; several streams in a row are read as one.
final class XZStream: ByteStream {
    private let source: any ByteStream
    private let coder: XZCoder
    private var pending = Data()
    private var sourceEnded = false
    private var isFinished = false
    /// What the coder delivered beyond what was asked for, and how much of it was handed on.
    private var ready = Data()
    private var readyOffset = 0
    private let control: StreamInterrupt?

    init(_ source: any ByteStream, control: StreamInterrupt? = nil) throws {
        self.source = source
        self.control = control
        coder = try XZCoder(encoding: false)
    }

    /// Never more than `count` bytes: the coder delivers in blocks of its own size, and a
    /// reader that asks for one TAR header must get no more than that.
    func read(upToCount count: Int) throws -> Data? {
        if readyOffset >= ready.count {
            guard let more = try decode(upToCount: count) else { return nil }
            if more.count <= count { return more }
            (ready, readyOffset) = (more, 0)
        }
        let end = min(ready.count, readyOffset + max(count, 1))
        defer { readyOffset = end }
        return ready.subdata(in: ready.startIndex + readyOffset..<ready.startIndex + end)
    }

    private func decode(upToCount count: Int) throws -> Data? {
        while !isFinished {
            try control?.check()
            if pending.isEmpty, !sourceEnded {
                if let block = try source.read(upToCount: 1 << 16) { pending = block } else { sourceEnded = true }
            }
            // Never told that the input ends: a stream says itself where it ends, and the
            // decoder then waits for more of one that is cut off, which is told apart below.
            let result = try coder.process(pending, finish: false, limit: max(count, 1 << 16))
            pending = Data(pending.dropFirst(result.consumed))
            if result.ended {
                // Padding between streams is made of zero bytes, however many: read on until
                // something else comes, or the file ends.
                while true {
                    // Cut at the first byte that is not padding, in one step.
                    pending = pending.firstIndex(where: { $0 != 0 }).map { Data(pending[$0...]) } ?? Data()
                    guard pending.isEmpty, !sourceEnded else { break }
                    try control?.check()
                    if let block = try source.read(upToCount: 1 << 16) { pending = block } else { sourceEnded = true }
                }
                if pending.isEmpty, sourceEnded { isFinished = true } else { try coder.restart() }
            } else if result.output.isEmpty, sourceEnded, pending.isEmpty {
                throw ArchiveError.damaged("the compressed data ends too early")
            }
            if !result.output.isEmpty { return result.output }
        }
        return nil
    }

    func close() {
        source.close()
    }
}

/// A program of the system run as a child process, without a shell: every argument reaches the
/// program exactly as given.
enum Tool {
    static let bsdtar = "/usr/bin/bsdtar"
    static let bzip2 = "/usr/bin/bzip2"
    static let gzip = "/usr/bin/gzip"

    /// What a child process sees of its surroundings: nothing of the user's. The tools read
    /// options from variables (`BZIP2`, `TAR_READER_OPTIONS`, …) and look for helper programs
    /// on the search path; neither is the caller's to steer. The UTF-8 locale is what lets
    /// bsdtar pass on names that are not ASCII.
    static let environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"]
    /// Of what a tool complains about, this much is kept; a tool that warns about every one
    /// of a million entries must not fill the memory.
    static let errorLimit = 64 << 10

    /// A process set up to run a tool: the surroundings above, and a working folder in which
    /// there is nothing to find by a relative path.
    static func process(_ executable: String, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty", isDirectory: true)
        return process
    }

    /// Reads a pipe to its end on a thread of its own (not one of the shared pool's, which a
    /// child that never ends would take away for good) and keeps the first `errorLimit` bytes.
    static func collect(_ handle: FileHandle, group: DispatchGroup, into store: @escaping @Sendable (Data) -> Void) {
        group.enter()
        Thread.detachNewThread {
            var kept = Data()
            let descriptor = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 1 << 14)
            while true {
                let got = retryingInterrupted {
                    buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                }
                guard got > 0 else { break }
                if kept.count < errorLimit { kept.append(contentsOf: buffer[..<min(got, errorLimit - kept.count)]) }
            }
            store(kept)
            group.leave()
        }
    }

    /// Runs the program with `input` on its standard input and returns its standard output.
    static func filter(_ executable: String, _ arguments: [String], input: Data) throws -> Data {
        let process = Self.process(executable, arguments)
        let (stdin, stdout, stderr) = (Pipe(), Pipe(), Pipe())
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Input is written on another thread while the output is read here, so neither pipe
        // fills up and blocks the child. A child that dies early must not kill the program
        // with SIGPIPE.
        let writeEnd = stdin.fileHandleForWriting
        _ = fcntl(writeEnd.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Both on threads of their own: one per piece on every core would otherwise use up
        // the threads the shared pool has for work that blocks.
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            try? writeEnd.write(contentsOf: input)
            try? writeEnd.close()
            group.leave()
        }
        // Written by the reading thread before it leaves the group, read here only after the wait.
        nonisolated(unsafe) var errors = Data()
        collect(stderr.fileHandleForReading, group: group) { errors = $0 }
        let output = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure(executable, errors) }
        return output
    }

    static func failure(_ executable: String, _ errors: Data) -> ArchiveError {
        let text = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (executable as NSString).lastPathComponent
        return .toolFailed(text.isEmpty ? "\(name) failed." : text)
    }
}

/// The standard output of a child process as a stream. Closing it before the end stops the
/// child, which is how a cancelled operation ends it; so does the `control`, from any thread,
/// and the read that waits for the child then throws.
///
/// Unchecked: `errors` and `isClosed` are guarded by `lock`; the rest is fixed in `init` or
/// belongs to the thread that reads the stream. Other threads only `stop` the child.
final class ProcessStream: ByteStream, @unchecked Sendable {
    private let process: Process
    private let executable: String
    private let output = Pipe()
    private let errorPipe = Pipe()
    private let errorsRead = DispatchGroup()
    private let lock = NSLock()
    private var errors = Data()
    private var isClosed = false
    private var ended = false
    private let control: StreamInterrupt?

    init(_ executable: String, _ arguments: [String], control: StreamInterrupt? = nil) throws {
        self.executable = executable
        self.control = control
        process = Tool.process(executable, arguments)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorPipe
        try process.run()
        Tool.collect(errorPipe.fileHandleForReading, group: errorsRead) { [weak self] text in
            guard let self else { return }
            lock.lock()
            errors = text
            lock.unlock()
        }
        control?.onSet { [weak self] in self?.stop() }
    }

    /// Ends the child; the read that waits for it then reaches the end of its output. Any thread.
    private func stop() {
        lock.lock()
        defer { lock.unlock() }
        if !isClosed, process.isRunning { process.terminate() }
    }

    deinit { close() }

    func read(upToCount count: Int) throws -> Data? {
        guard !ended else { return nil }
        try control?.check()
        // A stream that was closed (its reader stopped) has given up its pipe: nothing can be read
        // from it, and what it gave is not the whole output.
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed else { throw ArchiveError.cancelled }
        // A pipe hands over 64 KB at a time; a larger block would only be allocated in vain.
        let capacity = min(max(count, 1), 1 << 16)
        let descriptor = output.fileHandleForReading.fileDescriptor
        if let buffer = malloc(capacity) {
            let got = retryingInterrupted { Darwin.read(descriptor, buffer, capacity) }
            if got > 0 { return Data(bytesNoCopy: buffer, count: got, deallocator: .free) }
            free(buffer)
        }
        ended = true
        // A child that was stopped by the request has no failure to report.
        try control?.check()
        process.waitUntilExit()
        errorsRead.wait()
        lock.lock()
        let text = errors
        lock.unlock()
        if process.terminationStatus != 0 { throw Tool.failure(executable, text) }
        return nil
    }

    func close() {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        lock.unlock()
        guard !wasClosed else { return }
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }
}

/// What a compressed file says about its unpacked size without being unpacked.
enum CompressedSize {
    /// The size of an `.xz` file's contents, from the indexes at the ends of its streams
    /// (several streams in a row are one file). Nil when they cannot be read; every number in
    /// them is checked against the file.
    static func ofXZ(_ file: RandomAccessFile) -> UInt64? {
        var end = file.size
        var total: UInt64 = 0
        var (streams, steps) = (0, 0)
        while end > 0 {
            steps += 1
            guard end >= 32, end % 4 == 0, steps < 1 << 20, let footer = try? file.read(at: end - 12, count: 12),
                footer.count == 12
            else { return nil }
            // Zero bytes, four at a time, may stand between streams and after the last.
            if footer.suffix(4).allSatisfy({ $0 == 0 }) {
                end -= 4
                continue
            }
            guard footer[10] == 0x59, footer[11] == 0x5A else { return nil }
            var reader = ByteReader(footer)
            _ = reader.u32()
            let indexSize = (UInt64(reader.u32()) + 1) * 4
            guard indexSize <= 64 << 20, indexSize <= end - 24,
                let index = try? file.read(at: end - 12 - indexSize, count: Int(indexSize)),
                index.count == Int(indexSize), index[0] == 0
            else { return nil }
            var position = 1
            func number() -> UInt64? {
                var (value, shift) = (UInt64(0), UInt64(0))
                while position < index.count, shift < 63 {
                    let byte = index[position]
                    position += 1
                    value |= UInt64(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { return value }
                    shift += 7
                }
                return nil
            }
            guard let blocks = number(), blocks <= indexSize / 2 else { return nil }
            var packed: UInt64 = 0
            for _ in 0..<blocks {
                guard let unpadded = number(), let unpacked = number(), unpadded <= end else { return nil }
                let (sum, overflow) = total.addingReportingOverflow(unpacked)
                guard !overflow else { return nil }
                total = sum
                packed += (unpadded + 3) & ~3
                guard packed <= end else { return nil }
            }
            let streamSize = 12 + packed + indexSize + 12
            guard streamSize <= end, let head = try? file.read(at: end - streamSize, count: 6),
                [UInt8](head) == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
            else {
                return nil
            }
            end -= streamSize
            streams += 1
        }
        return streams > 0 ? total : nil
    }

    /// What the last four bytes of a `.gz` file say: the size of the contents, counted in 32
    /// bits. That is the size itself for one stream of less than 4 GB, which is what nearly
    /// every such file is, but nothing in the file proves it. A number too small for the
    /// compressed data to have come from is raised by the 4 GB steps it must have lost.
    static func claimedByGzip(_ file: RandomAccessFile) -> UInt64? {
        guard file.size >= 18, let tail = try? file.read(at: file.size - 4, count: 4), tail.count == 4 else {
            return nil
        }
        var reader = ByteReader(tail)
        var size = UInt64(reader.u32())
        // Deflate never makes data noticeably larger: the contents are about as large as the
        // file at the least.
        let least = file.size - file.size / 64
        while size < least { size += 1 << 32 }
        return size
    }
}

extension ArchiveFormat.Codec {
    /// Decompresses the local file at `url`.
    /// With a `control`, the stream ends with an error once the request is set.
    func decompressing(_ file: RandomAccessFile, control: StreamInterrupt? = nil) throws -> any ByteStream {
        switch self {
        case .gzip: return InflateStream(FileRangeStream(file), wrapping: .gzip, control: control)
        case .xz: return try XZStream(FileRangeStream(file), control: control)

        case .bzip2:
            // The child opens the file by its path: it must still be the file that was listed.
            guard file.isStillAtItsPath else {
                throw ArchiveError.changedOutside((file.path as NSString).lastPathComponent)
            }
            return try ProcessStream(Tool.bzip2, ["-dc", "--", file.path], control: control)
        }
    }
}

/// Compresses a stream of bytes on all cores: the stream is cut into pieces, the pieces are
/// compressed at the same time and written in order. Each of the three formats allows that:
/// deflate pieces join into one stream, and BZIP2 and XZ files may consist of several streams.
/// Used by one thread; the pieces are compressed on the others.
final class ParallelCompressor {
    enum Method: Equatable {
        case none
        case gzip(level: Int)
        case bzip2(level: Int)
        case xz
    }

    private let method: Method
    private let output: OutputFile
    private var buffer = Data()
    private var crc: UInt32 = 0
    private var total: UInt64 = 0
    private var wroteAnything = false
    private let pieceSize: Int
    private let windowSize: Int

    init(_ method: Method, to output: OutputFile, modified: Date = Date()) throws {
        self.method = method
        self.output = output
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch method {
        case .none: (pieceSize, windowSize) = (1 << 20, 1 << 20)
        case .gzip: (pieceSize, windowSize) = (1 << 20, (1 << 20) * cores)
        case .bzip2: (pieceSize, windowSize) = (4 << 20, (4 << 20) * cores)

        // The LZMA encoder needs a lot of memory per stream, so fewer run at once.
        case .xz: (pieceSize, windowSize) = (8 << 20, (8 << 20) * min(cores, 4))
        }
        if case .gzip = method {
            var header = Data([0x1F, 0x8B, 8, 0])
            header.appendLE(UInt32(max(0, min(modified.timeIntervalSince1970, Double(UInt32.max)))))
            header.append(contentsOf: [0, 3])
            try output.write(header)
        }
    }

    func write(_ data: Data) throws {
        if method == .none {
            try output.write(data)
            return
        }
        buffer.append(data)
        if buffer.count >= windowSize { try drain(final: false) }
    }

    func finish() throws {
        try drain(final: true)
        if case .gzip = method {
            var trailer = Data()
            trailer.appendLE(crc)
            trailer.appendLE(UInt32(truncatingIfNeeded: total))
            try output.write(trailer)
        }
    }

    private func drain(final: Bool) throws {
        // (Without compression `write` passes everything on at once: only the empty last piece is left.)
        var pieces: [Data] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= pieceSize || (final && offset < buffer.endIndex) {
            let end = min(offset + pieceSize, buffer.endIndex)
            pieces.append(buffer.subdata(in: offset..<end))
            offset = end
        }
        buffer = Data(buffer[offset...])
        // An empty input still has to become a valid (empty) compressed file.
        if final, pieces.isEmpty, !wroteAnything || isDeflate { pieces = [Data()] }
        guard !pieces.isEmpty else { return }
        let method = self.method
        let lastIndex = pieces.count - 1
        let results = Parallel.map(Array(pieces.enumerated()), serialBelow: 2) {
            index,
            piece -> Result<(Data, UInt32), any Error> in
            Result {
                switch method {
                case .gzip(let level):
                    return (
                        try Deflater.piece(piece, level: level, final: final && index == lastIndex), CRC32.of(piece)
                    )

                case .bzip2(let level):
                    return (try Tool.filter(Tool.bzip2, ["-c", "-\(max(1, min(level, 9)))"], input: piece), 0)

                case .xz: return (try XZCoder.compress(piece), 0)
                case .none: return (piece, 0)
                }
            }
        }
        for (piece, result) in zip(pieces, results) {
            let (packed, pieceCRC) = try result.get()
            crc = CRC32.combine(crc, pieceCRC, secondLength: piece.count)
            total += UInt64(piece.count)
            try output.write(packed)
            wroteAnything = true
        }
    }

    private var isDeflate: Bool {
        if case .gzip = method { return true }
        return false
    }
}
