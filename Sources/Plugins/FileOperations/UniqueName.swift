public import AFMKernel
public import Foundation

/// Free names for new items, and what is at a location, asked so that a cancellation ends the question.
public enum UniqueName {
    /// A free name next to `url`: `report (2).txt`, `report (3).txt` (spec 07 › Auto-rename names).
    ///
    /// `isTaken` names locations that are spoken for although nothing is there yet. With a
    /// `cancellation` flag the looks at the file system end when it is set; the name that comes
    /// back then is not known to be free, and whoever asked is being stopped.
    public static func available(
        for url: URL,
        in fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag? = nil,
        isTaken: (URL) -> Bool = { _ in false }
    ) -> URL {
        available(for: url) { candidate in
            item(at: candidate, in: fileSystems, cancellation) != nil || isTaken(candidate)
        }
    }

    /// What is at a location, asked so that the question ends with `cancellation` when there is one.
    internal static func item(at url: URL, in fileSystems: FileSystemRegistry, _ cancellation: CancellationFlag?)
        -> FileItem?
    {
        guard let cancellation else {
            return fileSystems.item(at: url)
        }
        return (try? fileSystems.provider(for: url))?.item(at: url, cancellation: cancellation)
    }

    /// The same with the question "is this name in use?" left to the caller.
    public static func available(for url: URL, exists: (URL) -> Bool) -> URL {
        guard exists(url) else {
            return url
        }
        let (base, ext) = FileItem.split(url.lastPathComponent)
        let folder = url.deletingLastPathComponent()
        func candidate(_ counter: Int) -> URL {
            folder.appending(name: ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)")
        }
        var counter = 2
        while exists(candidate(counter)) {
            counter += 1
        }
        return candidate(counter)
    }
}
