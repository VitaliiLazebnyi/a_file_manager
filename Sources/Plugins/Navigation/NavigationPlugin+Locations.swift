import AFMContracts
import AFMKernel
import Foundation

/// Where a move leads, worked out from the locations and texts alone (no file system, any thread).
extension NavigationPlugin {
    /// The place a directory belongs to, and the one `delta` steps further in the volume list
    /// (wrapping around): the disks when there are several, otherwise every place.
    ///
    /// Nil when there is nowhere else to go. Works on the locations alone.
    nonisolated internal static func neighbourPlace(of directory: URL, in places: [Place], delta: Int) -> Place? {
        let disks = places.filter { $0.kind == .internalDisk || $0.kind == .externalDisk }
        let candidates = disks.count > 1 ? disks : places
        guard candidates.count > 1 else {
            return candidates.first { !$0.url.isSameLocation(as: directory) }
        }
        // The place that holds the directory is the one with the longest path around it.
        let current = candidates.indices
            .filter { index in
                let place = candidates[index].url
                return directory.isSameLocation(as: place) || directory.isInside(place)
                    || (place.path == "/" && place.scheme == directory.scheme)
            }
            .max { candidates[$0].url.path.count < candidates[$1].url.path.count }
        guard let current else {
            return delta >= 0 ? candidates.first : candidates.last
        }
        return candidates[((current + delta) % candidates.count + candidates.count) % candidates.count]
    }

    /// The first line of a text from the clipboard as a path: without the quotes and spaces a
    /// path copied from a terminal or a document tends to come with.
    ///
    /// Nil when nothing is left.
    nonisolated internal static func path(fromClipboard text: String) -> String? {
        // Only the first line that has anything on it is looked at, however long the text is: the
        // first 8 KB of it (a path is not longer), cut at a byte (rounded down to a whole code point),
        // which only touches the last character.
        let head =
            text.utf8.count > 8_192 ? text[..<text.utf8.index(text.utf8.startIndex, offsetBy: 8_192)] : Substring(text)
        let line = head.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isNewline).first
        let path = String(line ?? "")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return path.isEmpty ? nil : path
    }
}
