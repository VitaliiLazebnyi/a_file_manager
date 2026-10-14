import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// `PathSafety` and `URL.appending(safeName:)` for names and relative paths from outside (an
/// archive, a server): what passes stays below the folder it is meant for, whatever the text
/// holds, and what is refused is refused for a reason the specification names.
@Suite
internal struct PathSafetyProperties {
    /// The folder the paths are meant for.
    private static let root = URL(fileURLWithPath: "/tmp/afm-root")

    /// Pieces of names: ordinary ones, the dot names, a slash with an accent after it (one
    /// character, but the byte `/`), a zero byte, an accent on its own.
    private static let pieces = ["a", "b", ".", "..", "\u{E9}", "/\u{301}", "\u{0}", "\u{301}", " ", "~"]

    /// Names, some of them with a slash in them.
    private static let name = Generate.text(from: pieces + ["/"], lengths: 0...4)

    /// Relative paths: names joined with slashes, empty ones and dot names among them.
    private static let path = Generate.text(from: pieces, lengths: 0...3).array(0...5).map { $0.joined(separator: "/") }

    /// The definition, by bytes.
    private static func isSafe(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return !bytes.isEmpty && bytes != [0x2E] && bytes != [0x2E, 0x2E] && !bytes.contains(0x2F) && !bytes.contains(0)
    }

    /// Whether a path below the root, written out with its dot names resolved, still lies below it.
    private static func staysBelow(_ relative: String) -> Bool {
        var depth = 0
        var wentAbove = false
        for part in relative.utf8.split(separator: 0x2F, omittingEmptySubsequences: true) {
            if part.elementsEqual([0x2E, 0x2E]) {
                depth -= 1
                wentAbove = wentAbove || depth < 0
            } else if !part.elementsEqual([0x2E]) {
                depth += 1
            }
        }
        return !wentAbove && depth > 0
    }

    /// Whether `isContained` answers for the root and `path` what resolving the dot names says.
    ///
    /// A path with a zero byte names no file (a URL's path ends there): for those it is enough
    /// that nothing is taken for inside that is not.
    private static func isContainedAsExpected(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: root.path + "/" + path)
        let contained = PathSafety.isContained(url, in: root)
        return path.utf8.contains(0) ? !contained || staysBelow(path) : contained == staysBelow(path)
    }

    /// Whether the names and the location made of a relative path are what its bytes say.
    private static func isCutAsItsBytesSay(_ path: String, trailing: Bool) -> Bool {
        var bytes = Array(path.utf8)
        if trailing, bytes.last == 0x2F {
            bytes.removeLast()
        }
        let parts = bytes.split(separator: 0x2F, omittingEmptySubsequences: false)
            .map { String(bytes: $0, encoding: .utf8) ?? "\u{FFFD}" }
        let acceptable = !bytes.isEmpty && parts.allSatisfy(isSafe)
        let names = PathSafety.components(ofRelativePath: path, allowingTrailingSeparator: trailing)
        guard !names.isEmpty else {
            return !acceptable
        }
        let location = names.reduce(root) { $0.appending(name: $1) }
        return acceptable && names == parts && PathSafety.isContained(location, in: root)
            && location.path == root.path + "/" + names.joined(separator: "/")
    }

    /// A name is safe exactly when it is not empty, not a dot name, and holds no `/` or zero byte;
    /// a safe name added to a folder names an entry directly inside it.
    @Test
    internal func safeNamesAreThoseTheDefinitionAllows() {
        expectProperty(Self.name, count: 2_000) { name in
            let added = Self.root.appending(safeName: name)
            let inside = added.map { url in
                url.deletingLastPathComponent().path == Self.root.path && url.lastPathComponent == name
            }
            return PathSafety.isSafeName(name) == Self.isSafe(name) && (inside ?? !Self.isSafe(name))
        }
    }

    /// A relative path is cut at every `/` byte into its names, and accepted exactly when every
    /// name is safe; its location then lies below the root, at the place the names spell.
    @Test
    internal func relativePathsAreAcceptedOnlyWhenEveryNameIsSafe() {
        let cases = Self.path.flatMap { path in Generate.bool.map { (path: path, trailing: $0) } }
        expectProperty(cases, count: 2_000) { path, trailing in Self.isCutAsItsBytesSay(path, trailing: trailing) }
    }

    /// A location written as text below the root lies inside it exactly when it still does with
    /// its dot names resolved, empty names (`root//../a`) read as the file system reads them.
    @Test
    internal func containmentFollowsTheDotNames() {
        expectProperty(Self.path, count: 2_000) { path in Self.isContainedAsExpected(path) }
    }
}
