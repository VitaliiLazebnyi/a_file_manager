/// Sums that cannot overflow, for sizes and offsets read from files.
extension UInt64 {
    /// The sum, or the largest number when it does not fit: sizes read from a file may be anything.
    internal func plusClamped(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
