import Darwin.C

/// "File size > 1.5 Mbytes" (spec 09 › Advanced tab).
public struct SizeRule: Codable, Equatable, Sendable {
    /// How the size of a file is compared with the figure, in the order of the menu; stored by its number.
    public enum Comparison: Int, Codable, CaseIterable, Sendable {
        /// The size shows as the figure.
        case equal = 0
        /// The size is above the figure.
        case greater = 1
        /// The size is below the figure.
        case less = 2

        /// The sign in the menu.
        public var title: String { ["=", ">", "<"][rawValue] }
    }

    /// The unit of the figure, in the order of the menu; stored by its number.
    public enum Unit: Int, Codable, CaseIterable, Sendable {
        /// Bytes.
        case bytes = 0
        /// Units of 1,024 bytes.
        case kilobytes = 1
        /// Units of 1,024 kbytes.
        case megabytes = 2
        /// Units of 1,024 Mbytes.
        case gigabytes = 3

        /// The title in the menu.
        public var title: String { ["bytes", "kbytes", "Mbytes", "Gbytes"][rawValue] }
        /// The bytes in one unit.
        public var factor: Double { pow(1_024, Double(rawValue)) }
    }

    /// How the size is compared.
    public var comparison: Comparison
    /// Fractions are allowed: 0.1 Gbytes.
    public var value: Double
    /// The unit of `value`.
    public var unit: Unit

    /// The figure in bytes; an absurd value (a huge number, not a number) is held to what a
    /// size can be, not trapped on.
    public var bytes: Int64 {
        let exact = (value * unit.factor).rounded()
        guard !exact.isNaN else {
            return 0
        }
        return exact >= 9.2e18 ? Int64.max : exact <= -9.2e18 ? Int64.min : Int64(exact)
    }

    /// The first size above the figure that still shows as it (`= 2 kbytes` ends at 3,072).
    public var upperBytes: Int64 {
        let step = unit == .bytes ? 1 : Int64(unit.factor)
        let (end, overflow) = bytes.addingReportingOverflow(step)
        return overflow ? Int64.max : end
    }

    /// A rule that compares the size of a file with `value` in `unit` by `comparison`.
    public init(_ comparison: Comparison, _ value: Double, _ unit: Unit = .bytes) {
        self.comparison = comparison
        self.value = value
        self.unit = unit
    }

    /// Whether a file of `size` bytes passes.
    ///
    /// `=` in a unit larger than bytes takes every size that shows as this figure: `= 2 kbytes`
    /// finds 2,048 to 3,071 bytes.
    public func matches(_ size: Int64) -> Bool {
        let figure = bytes
        switch comparison {
        case .greater:
            return size > figure

        case .less:
            return size < figure

        case .equal:
            return unit == .bytes ? size == figure : (figure..<upperBytes).contains(size)
        }
    }
}
