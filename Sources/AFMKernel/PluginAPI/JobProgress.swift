import Foundation

/// How far a long operation is (spec 07 › Progress window).
public struct JobProgress: Sendable {
    /// What is being worked on, ready to show: for a copy, `From: …` and `To: …`.
    public var lines: [String]
    /// Files plus folders.
    public var itemsDone: Int
    public var itemsTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public init(lines: [String], itemsDone: Int, itemsTotal: Int, bytesDone: Int64 = 0, bytesTotal: Int64 = 0) {
        self.lines = lines
        self.itemsDone = itemsDone
        self.itemsTotal = itemsTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }

    /// What speed and remaining time are measured in: bytes when the job moves data, else items.
    public var measuresBytes: Bool { bytesTotal > 0 }
    public var amountDone: Int64 { measuresBytes ? bytesDone : Int64(itemsDone) }
    public var amountTotal: Int64 { measuresBytes ? bytesTotal : Int64(itemsTotal) }

    /// Overall progress 0…1.
    public var fraction: Double {
        amountTotal > 0 ? min(1, Double(amountDone) / Double(amountTotal)) : 0
    }
}
