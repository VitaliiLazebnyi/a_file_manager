/// Sums of sizes that come from outside (an archive may declare any size for its entries)
/// must not stop the program when they leave the range of a number.
extension Int64 {
    /// The sum, or the nearest end of the range when the sum does not fit.
    public func addingSaturated(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other < 0 ? .min : .max) : sum
    }

    /// The difference, or the nearest end of the range when it does not fit.
    public func subtractingSaturated(_ other: Int64) -> Int64 {
        let (difference, overflow) = subtractingReportingOverflow(other)
        return overflow ? (other < 0 ? .max : .min) : difference
    }

    /// The product, or the nearest end of the range when it does not fit.
    public func multipliedSaturated(by other: Int64) -> Int64 {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? ((self < 0) != (other < 0) ? .min : .max) : product
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

    /// The product, or the nearest end of the range when it does not fit.
    public func multipliedSaturated(by other: Int) -> Int {
        let (product, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? ((self < 0) != (other < 0) ? .min : .max) : product
    }
}
