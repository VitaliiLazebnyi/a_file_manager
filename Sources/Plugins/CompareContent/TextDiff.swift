public import AFMKernel

/// Two texts laid side by side (spec 09 › Display).
///
/// Pure and UI-free; computing it is the slow part of the comparison and belongs on a background
/// thread.
public struct TextDiff: Equatable, Sendable {
    /// The within-line comparison covers this many characters (spec 09 › Comparison rules).
    public static let inlineLimit = 4_096

    /// The rows of the two panes, top to bottom.
    public let rows: [DiffRow]
    /// The differences as ranges of rows; a run of differing rows is one difference
    /// (spec 09 › Window, Next / Previous difference).
    public let blocks: [Range<Int>]

    /// Whether the texts have no difference under the options they were compared with.
    public var isIdentical: Bool { blocks.isEmpty }

    /// Compares two texts line by line, lines counting as equal by `options`.
    ///
    /// `anchors` are pairs of lines the user said belong together ("Resync comparison from
    /// here"): the texts before and after each are compared on their own. `costLimit` bounds the effort as in
    /// `Myers.diff`; the rows are cut short when `cancellation` is set.
    public static func compute(
        left: [TextLine],
        right: [TextLine],
        options: DiffOptions = DiffOptions(),
        anchors: [(left: Int, right: Int)] = [],
        costLimit: Int? = nil,
        cancellation: CancellationFlag? = nil
    ) -> Self {
        Comparison(
            left: left,
            right: right,
            options: options,
            costLimit: costLimit,
            cancellation: cancellation,
            hashes: options.hashes
        )
        .diff(anchors: anchors)
    }

    /// The runs of rows that are not equal.
    internal static func blocks(of rows: [DiffRow]) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var start: Int?
        for (index, row) in rows.enumerated() {
            if row.kind == .equal {
                if let begun = start {
                    found.append(begun..<index)
                }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let begun = start {
            found.append(begun..<rows.count)
        }
        return found
    }

    /// The lines of the right text put together from the rows: the right file again, which is
    /// what makes a set of rows a correct diff.
    public func rebuiltRight<Line>(left _: [Line], right: [Line]) -> [Line] {
        rows.compactMap { row in
            switch row.kind {
            case .equal, .changed, .added:
                return row.right.map { index in right[index] }

            case .removed:
                return nil
            }
        }
    }
}
