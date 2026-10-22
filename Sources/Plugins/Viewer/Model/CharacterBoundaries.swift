import AFMKernel
import Foundation

/// Where the characters of a text in a code page of more than one byte (932, 936, 949, 950, EUC-JP, GB 18030) begin.
///
/// A piece cut out of such a text can only be decoded from the start of a character: a lead byte
/// pairs with the byte after it whatever that is (from 0x40 on), so starting one byte off reads
/// every character after it wrong until a byte below 0x40 (a line end, a space, a digit) stands in
/// the way. In a long run of nothing but two-byte characters there is none.
///
/// The boundaries are found, not guessed: the character that follows a byte that cannot be a
/// lead byte begins right after it, and from a known boundary the characters are counted off
/// forward, exactly as the decoder counts them. The boundary at the start of every block of
/// `spacing` bytes is kept once found, so a search through a long run reads each part of it
/// once. Safe to use from several threads: `known` is guarded by `lock`, and the rest is
/// immutable.
internal final class CharacterBoundaries: @unchecked Sendable {
    private let source: any ByteSource
    private let content: Range<Int64>
    private let table: CodeTable
    private let spacing: Int64
    private let lock = NSLock()
    /// Block number → the last character start at or before the block's first byte.
    private var known: [Int64: Int64] = [:]
    private let computing = NSLock()

    internal init(source: any ByteSource, content: Range<Int64>, encoding: ViewerEncoding, spacing: Int = 16 << 10) {
        self.source = source
        self.content = content
        table = CodeTable.table(for: encoding)
        self.spacing = Int64(max(16, spacing))
        known[0] = content.lowerBound
    }

    /// How many blocks have a boundary now (for tests).
    internal var blockCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return known.count
    }

    private func start(ofBlock block: Int64) -> Int64 { content.lowerBound + block * spacing }

    private func cached(_ block: Int64) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return known[block]
    }

    /// The most boundaries kept: one per 16 KB would make a map of millions for a file of
    /// gigabytes.
    ///
    /// A search that comes back to a block that was let go finds it again from the nearest one that
    /// is kept.
    internal static let keptLimit = 1 << 16

    private func remember(_ block: Int64, _ boundary: Int64) {
        lock.lock()
        if known.count >= Self.keptLimit, known[block] == nil {
            // The start of the text stays; the rest is found again where it is needed.
            known = [0: content.lowerBound]
        }
        known[block] = boundary
        lock.unlock()
    }

    /// `source.read`, which must give at least `needed` bytes: the text is read inside the length
    /// the source had, so fewer means the file became shorter, and what the boundaries say would
    /// be guessed.
    private func read(at offset: Int64, count: Int, needed: Int, _ cancellation: CancellationFlag?) throws -> Data {
        let data = try source.read(at: offset, count: count, interruptedBy: cancellation)
        guard data.count >= needed else { throw ViewerError.fileChanged }
        return data
    }

    /// The start of the character that the byte at `offset` belongs to: `offset` itself when a
    /// character begins there.
    ///
    /// Reads at most one block, plus what finding the block's boundary needs the first time.
    internal func characterStart(atOrBefore offset: Int64, cancellation: CancellationFlag? = nil) throws -> Int64 {
        let offset = min(max(offset, content.lowerBound), content.upperBound)
        let block = (offset - content.lowerBound) / spacing
        let from = try boundary(ofBlock: block, cancellation)
        guard offset > from else {
            return from
        }
        let data = try read(
            at: from,
            count: Int(offset - from) + table.longestCharacter,
            needed: Int(offset - from),
            cancellation
        )
        return from + Int64(walk(data, from: 0, whileAtOrBefore: Int(offset - from)))
    }

    /// Counts characters off from index `from` of `data` (a boundary) and returns the index of
    /// the last character start at or before `limit`.
    ///
    /// A lead byte pairs with the next byte when that is 0x40 or more; the byte after the data is
    /// not known, so a lead at the very end is taken as the stray byte the decoder makes of it only
    /// when `data` reaches the end of the file.
    private func walk(_ data: Data, from: Int, whileAtOrBefore limit: Int) -> Int {
        var index = from
        // Never past the bytes there are, whatever was asked for.
        let limit = min(limit, data.count)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            while index < limit {
                // Too few bytes to tell (the end of the file): the first byte is a stray one.
                let next = index + max(1, table.characterLength(bytes, at: index))
                if next > limit { break }
                index = next
            }
        }
        return index
    }

    /// The last character start at or before the first byte of `block`.
    private func boundary(ofBlock block: Int64, _ cancellation: CancellationFlag?) throws -> Int64 {
        if let hit = cached(block) {
            return hit
        }
        // One thread at a time works its way back, the others then find the result.
        // A thread that waits for the one at work can still be stopped.
        while !computing.try() {
            try cancellation?.throwIfCancelled()
            if let hit = cached(block) {
                return hit
            }
            usleep(2_000)
        }
        defer { computing.unlock() }
        if let hit = cached(block) {
            return hit
        }
        // Back to a block with a known boundary, or to one that has a byte which is no lead
        // byte, and so a boundary right after it.
        // The boundary of block 0, the start of the text, is always known: the walk back ends
        // there at the latest.
        var anchor = block - 1
        var current: (block: Int64, boundary: Int64) = (0, content.lowerBound)
        while anchor > 0 {
            try cancellation?.throwIfCancelled()
            if let hit = cached(anchor) {
                current = (anchor, hit)
                break
            }
            let lower = start(ofBlock: anchor)
            let upper = min(content.upperBound, start(ofBlock: anchor + 1))
            let data = try read(at: lower, count: Int(upper - lower) + 1, needed: Int(upper - lower), cancellation)
            if let last = (0..<Int(upper - lower)).last(where: { table.isSynchronizing(data[data.startIndex + $0]) }) {
                // The character after a byte that is no lead byte begins right behind it.
                let sync = lower + Int64(last) + 1
                let boundary = try advance(from: sync, toBlock: anchor + 1, cancellation)
                remember(anchor + 1, boundary)
                current = (anchor + 1, boundary)
                break
            }
            anchor -= 1
        }
        while current.block < block {
            try cancellation?.throwIfCancelled()
            let next = current.block + 1
            current = (next, try advance(from: current.boundary, toBlock: next, cancellation))
            remember(current.block, current.boundary)
        }
        remember(current.block, current.boundary)
        return current.boundary
    }

    /// The last character start at or before the first byte of `block`, counted off from
    /// the boundary `from`, which is before that.
    private func advance(from: Int64, toBlock block: Int64, _ cancellation: CancellationFlag?) throws -> Int64 {
        let target = min(content.upperBound, start(ofBlock: block))
        guard target > from else {
            return from
        }
        let data = try read(
            at: from,
            count: Int(target - from) + table.longestCharacter,
            needed: Int(target - from),
            cancellation
        )
        return from + Int64(walk(data, from: 0, whileAtOrBefore: Int(target - from)))
    }
}
