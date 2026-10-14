/// How far a long operation is (spec 07 › Progress window).
public struct JobProgress: Sendable {
    /// What is being worked on, ready to show: for a copy, `From: …` and `To: …`.
    public var lines: [String]
    /// Files plus folders done so far.
    public var itemsDone: Int
    /// Files plus folders there are; 0 while unknown.
    public var itemsTotal: Int
    /// Bytes moved so far.
    public var bytesDone: Int64
    /// Bytes there are to move; 0 for a job that moves no data.
    public var bytesTotal: Int64

    /// What speed and remaining time are measured in: bytes when the job moves data, else items.
    public var measuresBytes: Bool { bytesTotal > 0 }
    /// What is done, in the unit of `measuresBytes`.
    public var amountDone: Int64 { measuresBytes ? bytesDone : Int64(itemsDone) }
    /// What there is to do, in the unit of `measuresBytes`.
    public var amountTotal: Int64 { measuresBytes ? bytesTotal : Int64(itemsTotal) }

    /// Overall progress 0…1.
    public var fraction: Double {
        amountTotal > 0 ? min(1, Double(amountDone) / Double(amountTotal)) : 0
    }

    /// The state of a job that has done `itemsDone` of `itemsTotal` items (and of bytes, for
    /// one that moves data).
    public init(lines: [String], itemsDone: Int, itemsTotal: Int, bytesDone: Int64 = 0, bytesTotal: Int64 = 0) {
        self.lines = lines
        self.itemsDone = itemsDone
        self.itemsTotal = itemsTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }
}
