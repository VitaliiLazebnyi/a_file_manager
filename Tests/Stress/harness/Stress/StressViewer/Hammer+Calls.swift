import AFMKernel
import Dispatch
import StressKit

@testable import ViewerPlugin

/// The calls the hammer threads make.
extension Hammer {
    /// The call a reader makes for a random `choice` from 0 to 3: rows half of the time.
    private static func readerOperation(_ choice: UInt64) -> String {
        switch choice {
        case 0, 1:
            "rows(from:count:100)"

        case 2:
            "row(containing:)"

        default:
            "row(ofLine:)"
        }
    }

    /// One call, cancelled after a random moment three times in ten; noted in the figures.
    internal func oneCall(isSearcher: Bool, random: inout Random) {
        let flag = CancellationFlag()
        let cancels = random.next() % 10 < 3
        if cancels {
            let delay = Int(random.next() % (isSearcher ? 50_000 : 3_000))
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + .microseconds(delay)) {
                    flag.cancel()
                }
        }
        let started = now()
        var threw = false
        let operation: String
        if isSearcher {
            operation = "search(absent)"
        } else {
            operation = Self.readerOperation(random.next() % 4)
        }
        do {
            try perform(operation, flag: flag, random: &random)
        } catch {
            threw = true
            if !flag.isCancelled, !document.cancellation.isCancelled {
                fail("\(label): \(operation) threw without a cancel", "\(error)")
            }
        }
        note(operation, now() - started, cancelled: flag.isCancelled, threw: threw)
    }

    /// Makes the call called `operation` and checks what it returns.
    private func perform(_ operation: String, flag: CancellationFlag, random: inout Random) throws {
        switch operation {
        case "search(absent)":
            try searchAbsent(flag: flag, random: &random)

        case "rows(from:count:100)":
            try readRows(document.rowCount, flag: flag, random: &random)

        case "row(containing:)":
            try rowContaining(flag: flag, random: &random)

        default:
            try rowOfLine(flag: flag, random: &random)
        }
    }

    /// Searches at most 256 MiB from a random place for a text that is not there.
    private func searchAbsent(flag: CancellationFlag, random: inout Random) throws {
        let pattern = try SearchPattern(
            "zzz_not_there_" + String(random.next() % 10),
            options: SearchOptions(),
            encoding: document.encoding
        )
        let from = Int64(random.next() % UInt64(max(1, document.content.upperBound)))
        // Bounded: at most 256 MiB from a random place, so one call ends in time.
        let end = min(document.content.upperBound, from + (256 << 20))
        let request = ViewerSearch.Request(pattern: pattern, start: from, backwards: random.next().isMultiple(of: 4))
        let subject = ViewerSearch.Subject(
            source: document.source,
            content: document.content.lowerBound..<end,
            encoding: document.encoding,
            boundaries: nil
        )
        let found = try ViewerSearch.find(request, in: subject, tuning: .standard, cancellation: flag) { _ in
            // No progress is wanted.
        }
        if let hit = found {
            fail("\(label): found a text that is not there", "\(hit)")
        }
    }

    /// Asks for 100 rows from a random one of the `count` known.
    private func readRows(_ count: Int, flag: CancellationFlag, random: inout Random) throws {
        guard count > 0 else {
            return
        }
        let first = Int(random.next() % UInt64(count))
        let rows = try document.rows(from: first, count: 100, cancellation: flag)
        check(rows, first: first, flagCancelled: flag.isCancelled)
        if rows.isEmpty, !flag.isCancelled, first < document.rowCount, document.readError == nil {
            fail("\(label): no rows for a known row", "row \(first) of \(document.rowCount)")
        }
    }

    /// Asks for the row of a random offset.
    private func rowContaining(flag: CancellationFlag, random: inout Random) throws {
        let offset = Int64(random.next() % UInt64(max(1, document.content.upperBound)))
        let row = try document.row(containing: offset, cancellation: flag)
        if let row, row < 0 || row >= max(1, document.rowCount) {
            fail("\(label): row(containing:) out of range", "\(row) of \(document.rowCount)")
        }
        if row == nil, document.isIndexComplete, !flag.isCancelled, document.rowCount > 0,
            document.readError == nil
        {
            fail("\(label): no row for an offset of a complete index", "offset \(offset)")
        }
    }

    /// Asks for the row of a random line.
    private func rowOfLine(flag: CancellationFlag, random: inout Random) throws {
        let lines = document.lineCount
        guard lines > 0 else {
            return
        }
        let line = 1 + Int(random.next() % UInt64(lines))
        let row = try document.row(ofLine: line, cancellation: flag)
        if let row, row < 0 || row >= document.rowCount {
            fail("\(label): row(ofLine:) out of range", "\(row) of \(document.rowCount)")
        }
    }
}
