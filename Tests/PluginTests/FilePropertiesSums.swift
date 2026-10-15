import Testing

@testable import FilePropertiesPlugin

/// The parts that work on many files at once, run on all cores: these are the tests to run
/// under the thread sanitizer.
@Suite
internal struct FilePropertiesSums {
    /// Sizes near the end of the range saturate instead of overflowing.
    @Test
    internal func sizesNearTheEndOfTheRangeAddUpWithoutStoppingTheProgram() {
        // An archive may declare any size for a member.
        let huge = SpaceTotals(bytes: .max - 5, allocated: .max, rounded: .max - 1, files: 1)
        let sum = huge + SpaceTotals(bytes: 100, allocated: 100, rounded: 100, files: 1)
        #expect(sum.bytes == .max && sum.allocated == .max && sum.rounded == .max && sum.files == 2)
        #expect(SpaceCalculator.round(.max, to: 4_096) > 0 && SpaceCalculator.round(.max - 3, to: 4_096) > 0)
    }
}
