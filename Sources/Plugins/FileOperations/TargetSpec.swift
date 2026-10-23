import AFMContracts
public import AFMKernel
public import Foundation

/// Where a Copy or Move goes: a folder plus a name mask (spec 07 › Target field).
public struct TargetSpec: Equatable, Sendable {
    /// The folder the items go to.
    public var directory: URL
    /// The name mask the new names are made with (`*.*` keeps them), or the one new name.
    public var mask: String
    /// The mask is a name to be taken as it is, even if it holds `*` or `?`.
    public var isExactName = false

    /// A target in `directory` with a name mask; the default keeps the names.
    public init(directory: URL, mask: String = "*.*") {
        self.directory = directory.standardized
        self.mask = mask
    }

    /// A target with one fixed name (for a rename typed by the user).
    public init(directory: URL, exactName: String) {
        self.init(directory: directory, mask: exactName)
        isExactName = true
    }

    /// Two targets are the same when their folders are the same place and their masks agree.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.directory.isSameLocation(as: rhs.directory) && lhs.mask == rhs.mask && lhs.isExactName == rhs.isExactName
    }

    /// Reads the target field.
    ///
    /// Relative paths, `..` and an empty path refer to the source folder. Looks at the file system
    /// to tell a folder from a new name, so it is not for the main thread. With a `cancellation`
    /// flag that look ends when the flag is set (a target on a server that has stopped answering);
    /// the text is then read as if nothing were there.
    public static func parse(
        _ text: String,
        sourceDirectory: URL,
        operandCount: Int,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag? = nil
    ) -> Self {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            return Self(directory: sourceDirectory)
        }
        // The last component, slashes at the end left out; a text of slashes only is the root.
        let last = typed.split(separator: "/").last.map(String.init) ?? "/"
        if last.contains("*") || last.contains("?") {
            let folder = String(typed.dropLast(last.count))
            return Self(directory: fileSystems.location(from: folder, relativeTo: sourceDirectory), mask: last)
        }
        let url = fileSystems.location(from: typed, relativeTo: sourceDirectory)
        if typed.hasSuffix("/") || last == ".." || last == "."
            || UniqueName.item(at: url, in: fileSystems, cancellation)?.isDirectory == true
        {
            return Self(directory: url)
        }
        // A plain new name renames a single item; for several items it names a folder to create.
        return operandCount == 1
            ? Self(directory: url.deletingLastPathComponent(), mask: last)
            : Self(directory: url)
    }

    /// Where the item called `sourceName` goes: the folder with the mask applied to the name.
    public func url(for sourceName: String) -> URL {
        directory.appending(name: isExactName ? mask : TargetMask.apply(mask, to: sourceName))
    }
}
