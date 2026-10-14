import AFMKernel
import Foundation
import LocalFileSystemPlugin
import StressKit

/// The local tree and the places its files go: what the background checks need, so that they can
/// run off the main thread.
internal struct Layout: Sendable {
    /// The tree the jobs start from.
    internal let source: URL
    /// Where the copies go.
    internal let destination: URL
    /// Where the moves go.
    internal let moved: URL
    /// The files of the tree.
    internal let manifest: [Entry]
    /// The paths of `manifest`.
    internal let manifestPaths: Set<String>
    /// How many folders hold the small files.
    internal let folderCount: Int
    /// The file systems the jobs use: the local one.
    internal let fileSystems: FileSystemRegistry

    /// The bytes of every file together.
    internal var totalBytes: Int {
        manifest.reduce(0) { $0 + $1.size }
    }

    /// The layout below `settings.root`.
    internal init(settings: Settings) {
        source = settings.root.appendingPathComponent("src")
        destination = settings.root.appendingPathComponent("dst")
        moved = settings.root.appendingPathComponent("moved")
        manifest = Entry.manifest(
            fileCount: settings.fileCount,
            folderCount: settings.folderCount,
            bigCount: settings.bigCount
        )
        manifestPaths = Set(manifest.map(\.path))
        folderCount = settings.folderCount
        fileSystems = FileSystemRegistry()
        fileSystems.register(LocalFileSystem())
    }

    /// Makes the tree unless it is there and intact, and empties the places the files go.
    internal func prepare() {
        if FileManager.default.fileExists(atPath: source.path),
            Tree.survey(source, entries: manifest).allSatisfy({ $0 == 1 })
        {
            say("tree exists and is intact")
        } else {
            Tree.removeQuickly(source)
            Tree.createDirectory(source)
            Tree.build(at: source, entries: manifest)
        }
        Tree.removeQuickly(destination)
        Tree.removeQuickly(moved)
    }

    /// Removes the tree and whatever the jobs left.
    internal func removeAll() {
        Tree.removeQuickly(source)
        Tree.removeQuickly(destination)
        Tree.removeQuickly(moved)
    }

    /// After a seed: the source is whole again, nothing is left at the moved place; then the
    /// copies and the moved place go.
    internal func verifyRestored(seed: Int) {
        let state = Tree.survey(source, entries: manifest)
        let bad = state.filter { $0 != 1 }.count
        if bad > 0 {
            Findings.shared.violation(
                "tree not restored after moving back",
                "seed \(seed): \(bad) files missing or different at the source"
            )
        }
        let rest = Tree.walk(moved)
        if let first = rest.files.first {
            Findings.shared.violation(
                "files left at the moved place after moving back",
                "seed \(seed): \(rest.files.count), e.g. \(first)"
            )
        }
        Tree.removeQuickly(moved)
        Tree.removeQuickly(destination)
    }
}
