import AFMKernel
import Foundation

/// By content: the pairs that size and date could not tell apart, read and compared.
extension SyncComparison {
    /// How a round of reading two files ends.
    private enum Round {
        /// The files differ.
        case different
        /// Both files ended together: they are the same.
        case same
        /// The blocks read agree; the files go on.
        case undecided
    }

    /// Reads two files side by side and stops at the first difference; `progress` is told the bytes compared.
    ///
    /// Throws `CancellationError` when cancelled. The blocks a reader hands out may be of any length; they are
    /// cut to match.
    internal static func sameContent(
        _ first: URL,
        _ second: URL,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag,
        progress: (Int) -> Void
    ) throws -> Bool {
        if cancellation.isCancelled {
            throw CancellationError()
        }
        var readers: [any FileReader] = []
        // A read blocked on a server ends as soon as the flag is set.
        var tokens: [AnyObject] = []
        defer {
            for reader in readers {
                reader.close()
            }
            withExtendedLifetime(tokens) {
                // The readers can be interrupted up to here.
            }
        }
        for url in [first, second] {
            let reader = try fileSystems.provider(for: url).read(url, cancellation: cancellation)
            readers.append(reader)
            tokens.append(cancellation.interrupting(reader))
        }
        var buffers = [Data(), Data()]
        var ended = [false, false]
        while !cancellation.isCancelled {
            // One block of each side per round, in a pool of its own (a long pair of files would keep every
            // block until it ends).
            let round = try autoreleasepool {
                try compareRound(readers, &buffers, &ended, progress: progress)
            }
            switch round {
            case .same:
                return true

            case .different:
                return false

            case .undecided:
                continue
            }
        }
        throw CancellationError()
    }

    /// Reads a block of each side that has none waiting, and compares as much as both have.
    private static func compareRound(
        _ readers: [any FileReader],
        _ buffers: inout [Data],
        _ ended: inout [Bool],
        progress: (Int) -> Void
    ) throws -> Round {
        for side in 0..<2 where !ended[side] && buffers[side].isEmpty {
            if let block = try readers[side].read(upToCount: blockSize), !block.isEmpty {
                buffers[side] = block
            } else {
                ended[side] = true
            }
        }
        let count = min(buffers[0].count, buffers[1].count)
        if count == 0 {
            // One side has ended: the files are the same only if the other has too.
            return buffers[0].isEmpty && buffers[1].isEmpty && ended[0] && ended[1] ? .same : .different
        }
        guard buffers[0].prefix(count) == buffers[1].prefix(count) else {
            return .different
        }
        buffers = buffers.map { buffer in Data(buffer.dropFirst(count)) }
        progress(count)
        return .undecided
    }

    /// Reads the pairs that size and date could not tell apart, on all cores.
    internal func compareContents(of rows: inout [SyncRow]) {
        let pending = rows.indices.filter { index in rows[index].state == .pending }
        guard !pending.isEmpty else {
            return
        }
        let candidates = pending.map { index in rows[index] }
        update { counts in
            counts.filesToCompare = pending.count
            // (A pair waits for its contents only when both sides are there.)
            counts.bytesToCompare = candidates.compactMap { row in row.left?.size }
                .reduce(Int64(0)) { total, size in total.addingSaturated(size) }
        }
        let states = Parallel.map(candidates) { row in self.contentState(of: row) }
        for (index, state) in zip(pending, states) {
            rows[index].state = state
            rows[index].defaultAction = SyncRow.proposal(for: state, asymmetric: options.asymmetric)
            rows[index].action = rows[index].defaultAction
        }
    }

    /// What reading a pair tells: equal or different; pending when cancelled or a file could not be read.
    private func contentState(of row: SyncRow) -> SyncState {
        guard !cancellation.isCancelled, let left = row.left, let right = row.right else {
            return .pending
        }
        defer {
            update { counts in counts.filesCompared += 1 }
        }
        do {
            let same = try Self.sameContent(
                left.url,
                right.url,
                fileSystems: fileSystems,
                cancellation: cancellation
            ) { bytes in
                self.update { counts in counts.bytesCompared += Int64(bytes) }
            }
            return same ? .equal : .different
        } catch {
            if !cancellation.isCancelled {
                note("\(fileSystems.displayPath(left.url)): \(error.localizedDescription)")
            }
            return .pending
        }
    }
}
