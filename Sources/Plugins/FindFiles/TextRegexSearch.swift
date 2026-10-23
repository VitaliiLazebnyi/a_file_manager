import AFMKernel
import Foundation

/// The search of one file with the regular expression of a `TextPattern`.
///
/// The file is decoded in pieces that end at a line break and each piece is matched with `^` and
/// `$` standing for the line ends, which is matching line by line without cutting the
/// text into lines.
internal struct TextRegexSearch {
    /// How reading one block went.
    private enum Step {
        case end
        case hit
        case more
        case stop
    }

    /// The expression.
    internal let regex: NSRegularExpression
    /// The encodings the file is decoded in, each on its own.
    internal let encodings: [TextEncoding]
    /// Counts the pieces the expression ran out of time on.
    internal let trip: RegexTrip
    /// Ends the search early; nil when it cannot be cancelled.
    internal let cancellation: CancellationFlag?

    /// Reads the file from `reader` in blocks of `blockSize` bytes.
    ///
    /// A piece that takes the expression too long ends the search of the file (it is not found in
    /// it), and a cancelled search ends at once, also in the middle of a piece.
    internal func run(_ reader: any FileReader, blockSize: Int) -> TextSearchOutcome {
        var decoders = encodings.map { TextLineDecoder(encoding: $0) }
        var gaveUp = false
        do {
            reading: while true {
                let step: Step = try autoreleasepool {
                    guard let block = try reader.read(upToCount: blockSize), !block.isEmpty else {
                        return .end
                    }
                    if cancellation?.isCancelled == true {
                        return .stop
                    }
                    for index in decoders.indices where matches(decoders[index].feed(block), gaveUp: &gaveUp) {
                        return .hit
                    }
                    return gaveUp ? .stop : .more
                }
                switch step {
                case .end:
                    break reading

                case .hit:
                    return .found

                case .more:
                    continue reading

                case .stop:
                    return .undecided
                }
            }
        } catch {
            return .undecided
        }
        if decoders.indices.contains(where: { matches(decoders[$0].finish(), gaveUp: &gaveUp) }) {
            return .found
        }
        return gaveUp ? .undecided : .missing
    }

    /// Whether the expression matches a piece of text, within `TextPattern.pieceBudget`.
    ///
    /// Nothing matches once the search has given up (`gaveUp`): the expression took too long for a piece,
    /// or for enough pieces of the search to be tripped.
    private func matches(_ text: String?, gaveUp: inout Bool) -> Bool {
        guard let text, !text.isEmpty, !gaveUp else {
            return false
        }
        if trip.isTripped {
            gaveUp = true
            return false
        }
        let outcome = FindRegex.firstMatch(regex, in: text, budget: TextPattern.pieceBudget) {
            cancellation?.isCancelled == true
        }
        switch outcome {
        case .matched:
            return true

        case .timedOut:
            gaveUp = true
            if cancellation?.isCancelled != true {
                trip.recordTimeout()
            }
            return false

        case .unmatched:
            return false
        }
    }
}
