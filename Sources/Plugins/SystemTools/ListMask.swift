import AFMKernel
import Foundation

/// Which files a list with subfolders includes: `*.doc *.txt`, or `*.* | *.bak` to leave
/// some out (spec 18 › Core syntax).
///
/// Folders are always listed and entered.
internal struct ListMask {
    private let include: FileMask?
    private let exclude: FileMask?

    /// The mask of `text`: the masks before a `|` include, those after it leave out.
    internal init(_ text: String) {
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .map { part in
                part.trimmingCharacters(in: .whitespaces)
            }
        // An empty include part means everything.
        include = parts.first.flatMap { $0.isEmpty ? nil : FileMask($0) }
        exclude = parts.count > 1 && !parts[1].isEmpty ? FileMask(parts[1]) : nil
    }

    /// Whether a file of that name is listed: included (everything is when no include part was
    /// given) and not left out.
    internal func matches(_ name: String) -> Bool {
        (include?.matches(name) ?? true) && !(exclude?.matches(name) ?? false)
    }
}
