/// Counts that come from outside (the number of entries an archive declares) must not stop
/// the program when they leave the range of a number.
extension Int {
    /// The sum, or the nearest end of the range when the sum does not fit.
    public func addingSaturated(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other < 0 ? .min : .max) : sum
    }
}
