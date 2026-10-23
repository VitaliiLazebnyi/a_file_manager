import AFMContracts
public import AFMKernel
import Foundation

/// A piece of information about a file that a rule of the Plugins tab can test: the built-in
/// ones (the `tc` pseudo-plugin of the spec) and every column a plugin registered
/// (spec 09 › Plugins tab).
public struct SearchField: Sendable {
    /// What a rule names the field by (`tc.name`, or the column's identifier).
    public let id: String
    /// The name shown in the field menu.
    public let title: String
    /// May block on the file system; called on the search's threads, several at once.
    public let value: @Sendable (FileItem) -> String

    /// The fields of the `tc` pseudo-plugin: name, extension, full name, path, size, date and permissions.
    public static func builtIn(fileSystems: FileSystemRegistry) -> [Self] {
        [
            Self(id: "tc.name", title: "Name") { $0.name },
            Self(id: "tc.ext", title: "Extension") { FileItem.split($0.name).ext },
            Self(id: "tc.fullname", title: "Full name with path") { fileSystems.displayPath($0.url) },
            Self(id: "tc.path", title: "Path") { fileSystems.displayPath($0.url.deletingLastPathComponent()) },
            Self(id: "tc.size", title: "Size in bytes") { $0.isDirectory ? "" : String($0.size) },
            Self(id: "tc.date", title: "Date") { Format.date($0.modified) },
            Self(id: "tc.attr", title: "Permissions") { Format.permissions($0.permissions) }
        ]
    }

    /// The built-in fields followed by the plugins' columns.
    public static func all(fileSystems: FileSystemRegistry, columns: ColumnRegistry?) -> [Self] {
        builtIn(fileSystems: fileSystems)
            + (columns?.all ?? [])
            .map { column in
                Self(id: column.id, title: column.title, value: column.value)
            }
    }
}
