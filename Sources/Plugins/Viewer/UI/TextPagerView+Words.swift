import Foundation

/// Words in the text of a row, for Ctrl+arrow and a double click: letters, digits and `_`.
extension TextPagerView {
    /// Where the next word starts after the UTF-16 place `index` of `text`; its end when there is none.
    internal static func wordStart(after index: Int, in text: String) -> Int {
        let units = Array(text.utf16)
        var place = index
        while place < units.count, isWordUnit(units[place]) { place += 1 }
        while place < units.count, !isWordUnit(units[place]) { place += 1 }
        return place
    }

    /// Where the word before the UTF-16 place `index` of `text` starts; 0 when there is none.
    internal static func wordStart(before index: Int, in text: String) -> Int {
        let units = Array(text.utf16)
        var place = min(index, units.count)
        while place > 0, !isWordUnit(units[place - 1]) { place -= 1 }
        while place > 0, isWordUnit(units[place - 1]) { place -= 1 }
        return place
    }

    /// The word around a place in a text, for a double click.
    internal static func wordRange(around index: Int, in text: String) -> Range<Int> {
        let units = Array(text.utf16)
        guard index < units.count, isWordUnit(units[index]) else {
            return index..<min(units.count, index + 1)
        }
        var lower = index
        var upper = index
        while lower > 0, isWordUnit(units[lower - 1]) { lower -= 1 }
        while upper < units.count, isWordUnit(units[upper]) { upper += 1 }
        return lower..<upper
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit).map { CharacterSet.alphanumerics.contains($0) || $0 == "_" } ?? true
    }
}
