import TestSupport
import Testing

@testable import AFMKernel

/// The saturating arithmetic of sizes against the exact result worked out in 128 bits and then
/// cut to the range of the type. (128-bit numbers came with macOS 15; the tests run on newer.)
@Suite
internal struct SaturatingProperties {
    /// Two numbers of 64 bits, the ends of the range among them.
    private static let pairs = Generate.int64.flatMap { first in Generate.int64.map { (first, $0) } }

    /// The exact value, or the nearest end of the range of `Int64`.
    @available(macOS 15, *)
    private static func clamped(_ exact: Int128) -> Int64 {
        exact > Int128(Int64.max) ? .max : (exact < Int128(Int64.min) ? .min : Int64(exact))
    }

    /// Sums of `Int64` are exact where they fit and the nearest end of
    /// the range where they do not.
    @Test
    internal func int64ArithmeticSaturates() {
        guard #available(macOS 15, *) else {
            return
        }
        expectProperty(Self.pairs, count: 5_000) { first, second in
            let (wide, other) = (Int128(first), Int128(second))
            return first.addingSaturated(second) == Self.clamped(wide + other)
        }
    }

    /// The same for `Int`, which is 64 bits wide on every Mac.
    @Test
    internal func intArithmeticSaturates() {
        guard #available(macOS 15, *) else {
            return
        }
        expectProperty(Self.pairs, count: 5_000) { first, second in
            let (one, other) = (Int(first), Int(second))
            let (wide, wideOther) = (Int128(first), Int128(second))
            return Int64(one.addingSaturated(other)) == Self.clamped(wide + wideOther)
        }
    }

    /// A number of another kind becomes the nearest number of 64 bits.
    @Test
    internal func otherNumbersAreClamped() {
        guard #available(macOS 15, *) else {
            return
        }
        let wide = Generate.int64.flatMap { high in Generate.int64.map { (high, $0) } }
        expectProperty(wide, count: 2_000) { high, low in
            let unsigned = UInt64(bitPattern: low)
            let exact = Int128(high) << 64 | Int128(unsigned)
            return Int64(saturating: unsigned) == Self.clamped(Int128(unsigned))
                && Int64(saturating: exact) == Self.clamped(exact)
                && Int64(saturating: Int32(truncatingIfNeeded: low)) == Int64(Int32(truncatingIfNeeded: low))
        }
    }
}
