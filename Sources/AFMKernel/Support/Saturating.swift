/// Sums of sizes that come from outside (an archive may declare any size for its entries)
/// must not stop the program when they leave the range of a number.
extension Int64 {
    /// The sum, or the nearest end of the range when the sum does not fit.
    public func addingSaturated(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other < 0 ? .min : .max) : sum
    }

    /// A number of another kind (a size read from a header, a count) as far as it fits.
    public init<Source: BinaryInteger>(saturating source: Source) {
        self = Int64(clamping: source)
    }
}

extension Int {
    /// The sum, or the nearest end of the range when the sum does not fit.
    public func addingSaturated(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other < 0 ? .min : .max) : sum
    }
}
