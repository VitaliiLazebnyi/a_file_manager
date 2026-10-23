/// The numbers of the counters: zero-filled, safe from overflow, and in letters.
extension RenameMask {
    /// `value` with zeros in front up to `digits` (at most `widestFill`), the sign before them.
    internal static func padded(_ value: Int, digits: Int) -> String {
        let text = value == Int.min ? String(value.magnitude) : String(abs(value))
        return (value < 0 ? "-" : "") + String(repeating: "0", count: max(0, min(digits, widestFill) - text.count))
            + text
    }

    /// `start + step * times`; a result beyond the range of numbers is an error of the mask
    /// (`<Error!>`), not a crash.
    internal static func number(_ start: Int, plus step: Int, times: Int) throws -> Int {
        let (distance, overflowed) = step.multipliedReportingOverflow(by: times)
        let (sum, overflowedAgain) = start.addingReportingOverflow(distance)
        guard !overflowed, !overflowedAgain else {
            throw RenameMaskError.numberTooLarge
        }
        return sum
    }

    /// `aa`, `ab`, … `az`, `ba`: the letters are the digits of a number in base 26, as wide
    /// as the start text and in its case.
    ///
    /// Letters that make a number too large for the counter are an error of the mask.
    internal static func alphabetic(_ start: String, advancedBy steps: Int) throws -> String {
        let isUpper = start.first?.isUppercase ?? false
        let base = UInt8(ascii: isUpper ? "A" : "a")
        var value = 0
        for byte in start.lowercased().utf8 {
            let (shifted, overflowed) = value.multipliedReportingOverflow(by: 26)
            let (next, overflowedAgain) = shifted.addingReportingOverflow(Int(byte - UInt8(ascii: "a")))
            guard !overflowed, !overflowedAgain else {
                throw RenameMaskError.numberTooLarge
            }
            value = next
        }
        let (advanced, overflowed) = value.addingReportingOverflow(steps)
        guard !overflowed else {
            throw RenameMaskError.numberTooLarge
        }
        value = max(0, advanced)
        var letters: [UInt8] = []
        repeat {
            letters.append(base + UInt8(value % 26))
            value /= 26
        } while value > 0
        while letters.count < start.count {
            letters.append(base)
        }
        return String(String.UnicodeScalarView(letters.reversed().map { Unicode.Scalar($0) }))
    }
}
