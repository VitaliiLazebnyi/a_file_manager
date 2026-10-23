/// The footer after a comparison (spec 09 › Status line).
///
/// Directories are not counted.
public struct SyncSummary: Equatable, Sendable {
    /// The files found, on either side or both.
    public var files = 0
    /// The pairs that are the same.
    public var identical = 0
    /// The pairs that differ, and those not compared or never synchronized.
    public var different = 0
    /// The files only on the left.
    public var uniqueLeft = 0
    /// The files only on the right.
    public var uniqueRight = 0

    /// The footer's text.
    public var text: String {
        files == 0
            ? "Files found: 0"
            : "Files found: \(files)  (Identical: \(identical), Different: \(different), "
                + "Unique left: \(uniqueLeft), Unique right: \(uniqueRight))"
    }

    /// The counts of the rows' files.
    public init(_ rows: [SyncRow]) {
        for row in rows where !row.isDirectory {
            files += 1
            switch row.state {
            case .leftOnly:
                uniqueLeft += 1

            case .rightOnly:
                uniqueRight += 1

            case .equal:
                identical += 1

            default:
                different += 1
            }
        }
    }
}
