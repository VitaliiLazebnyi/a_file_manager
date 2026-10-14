import Foundation

/// `FileMask` by its documented rules, worked out the slow way.
internal enum MaskReference {
    /// The form masks and names are compared in (the rule of the type: without case, accents composed).
    internal static func folded(_ text: String) -> [UInt32] {
        text.folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
            .unicodeScalars
            .map(\.value)
    }

    /// Whether `pattern` matches `name`, by the rules alone.
    ///
    /// Masks are separated by spaces or semicolons; `*` is any run and `?` exactly one character
    /// (a Unicode scalar of the folded name); everything else, brackets and backslashes included,
    /// stands for itself; `*` and `*.*` match every name; a mask that ends with a dot is, for a name
    /// without a dot, the mask without it.
    internal static func matches(_ pattern: String, _ name: String) -> Bool {
        let masks = folded(pattern).split { $0 == 0x20 || $0 == 0x3B }.map(Array.init)
        if masks.contains(where: { $0 == [0x2A] || $0 == [0x2A, 0x2E, 0x2A] }) {
            return true
        }
        let scalars = folded(name)
        let hasDot = scalars.contains(0x2E)
        return masks.contains { mask in
            wild(!hasDot && mask.last == 0x2E ? Array(mask.dropLast()) : mask, scalars)
        }
    }

    /// Whether one mask of `*`, `?` and literal scalars takes all of `scalars`.
    private static func wild(_ mask: [UInt32], _ scalars: [UInt32]) -> Bool {
        // reach[index]: the mask so far can take the first `index` characters of the name.
        var reach = [Bool](repeating: false, count: scalars.count + 1)
        reach[0] = true
        for token in mask {
            var next = [Bool](repeating: false, count: scalars.count + 1)
            if token == 0x2A {
                var any = false
                for index in 0...scalars.count {
                    any = any || reach[index]
                    next[index] = any
                }
            } else {
                for index in 0..<scalars.count where reach[index] && (token == 0x3F || token == scalars[index]) {
                    next[index + 1] = true
                }
            }
            reach = next
        }
        return reach[scalars.count]
    }
}
