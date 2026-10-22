import AFMKernel
import Foundation

/// A file-type specification of Show › Custom…: `*.bmp *.gif`, `*.* | *.bak`, `*.txt | */`
/// (spec 03 › Show files of type).
///
/// The masks before the `|` say which files are shown, the ones after it which are left out; an
/// exclusion that ends in a slash is about folders. Folders are shown unless such an exclusion
/// names them. Pure, safe on any thread.
struct DisplayMask: Sendable {
    let text: String
    private let includes: FileMask?
    private let excludes: FileMask?
    private let folderExcludes: FileMask?

    init(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        self.text = text
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        func words(_ part: String) -> [String] {
            part.split(whereSeparator: { $0 == " " || $0 == ";" }).map(String.init)
        }
        func mask(_ words: [String]) -> FileMask? { words.isEmpty ? nil : FileMask(words.joined(separator: " ")) }
        let excluded = parts.count > 1 ? words(parts[1]) : []
        // The Windows form of a folder exclusion, `name\`, is read as well.
        let isFolderMask = { (word: String) in word.hasSuffix("/") || word.hasSuffix("\\") }
        // Split without leaving out empty parts, the text has at least one part: all of it when it has no `|`.
        includes = mask(words(parts[0]))
        excludes = mask(excluded.filter { !isFolderMask($0) })
        folderExcludes = mask(excluded.filter(isFolderMask).map { String($0.dropLast()) }.filter { !$0.isEmpty })
    }

    /// True for `*.*`, `*` and nothing at all: every entry is shown, which is no filter.
    var showsEverything: Bool {
        excludes == nil && folderExcludes == nil && (includes == nil || ["*", "*.*"].contains(text))
    }

    func matches(_ item: FileItem) -> Bool {
        if item.isFolder {
            return !(folderExcludes?.matches(item.name) ?? false)
        }
        return (includes?.matches(item.name) ?? true) && !(excludes?.matches(item.name) ?? false)
    }

    /// The filter for a panel; nil when the specification shows everything.
    var filter: PanelFilter? {
        showsEverything ? nil : PanelFilter(title: text) { [self] in matches($0) }
    }
}
