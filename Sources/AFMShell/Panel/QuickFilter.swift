import AFMKernel
import Foundation

/// The quick filter of one tab (spec 03 › Quick filter): what was typed, and what it was laid over.
///
/// A tab has one filter (`PanelModel.filter`), which the Show menu's display filters use as well;
/// the quick filter therefore keeps the filter it found (`base`) and shows only what passes both.
/// Taking the quick filter away puts `base` back.
internal struct QuickFilter {
    /// What was typed.
    internal var text: String
    /// The display filter that was on when the quick filter was opened.
    internal let base: PanelFilter?
    /// The folder the filter belongs to; it does not survive a change of directory.
    internal let directory: URL

    /// What the model's filter is called while this quick filter is on.
    ///
    /// It starts with the title of `base`, so whoever set that still recognises it.
    internal var title: String {
        text.isEmpty ? (base?.title ?? "") : (base.map { $0.title + "  " } ?? "") + "⏷ " + text
    }

    /// The filter for the model; nil when nothing is typed and nothing lies below.
    internal var combined: PanelFilter? {
        guard !text.isEmpty else {
            return base
        }
        let (matches, base) = (Self.matcher(for: text), base)
        return PanelFilter(title: title) { item in matches(item.name) && (base?.matches(item) ?? true) }
    }

    /// Whether what is typed now lets through nothing that `old` did not: both are plain ASCII text
    /// (no mask), and the new contains the old.
    ///
    /// The list then only has to be filtered again from what it shows.
    internal static func narrows(from old: String, to new: String) -> Bool {
        guard !old.isEmpty, isPlainText(old), isPlainText(new) else {
            return false
        }
        return new.lowercased().contains(old.lowercased())
    }

    /// How typed text is compared with a name: as a file mask when it has a `*` or `?` in it,
    /// otherwise the name has to contain it.
    ///
    /// Upper and lower case are the same. The function may be called on any thread.
    internal static func matcher(for text: String) -> @Sendable (String) -> Bool {
        let pattern = text.lowercased()
        if pattern.contains("*") || pattern.contains("?") {
            return { fnmatch(pattern, $0.lowercased(), 0) == 0 }
        }
        let needle = Array(pattern.utf8)
        guard needle.allSatisfy({ $0 < 0x80 }) else {
            return { $0.range(of: pattern, options: .caseInsensitive) != nil }
        }
        // Every key press looks at every name: plain ASCII names are compared byte by byte.
        return { name in
            let quick =
                name.utf8.withContiguousStorageIfAvailable { ASCIIComparison.contains(needle, in: $0) } ?? .unknown
            guard quick == .unknown else {
                return quick == .match
            }
            return name.range(of: pattern, options: .caseInsensitive) != nil
        }
    }

    /// Plain ASCII without the characters of a mask.
    private static func isPlainText(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 < 0x80 && $0 != 0x2A && $0 != 0x3F }
    }
}
