public import Foundation

/// One entry of a directory, on whatever file system it lives (spec 03 › Rows in Full view).
public struct FileItem: Equatable, Sendable {
    /// What kind of entry it is: the flags a listing gives besides the name.
    public struct Kind: OptionSet, Hashable, Sendable {
        /// A directory, or a symbolic link that points to one.
        public static let directory = Self(rawValue: 1)
        /// A symbolic link; `directory` too when it points to one.
        public static let symlink = Self(rawValue: 2)
        /// A directory that is shown and opened like a file (a macOS bundle such as `.app`).
        public static let package = Self(rawValue: 4)
        /// Not shown unless the user asks for hidden entries (a leading dot, the hidden flag).
        public static let hidden = Self(rawValue: 8)
        /// Neither a file with contents nor a directory: a pipe, a device or a socket, or a
        /// link to one.
        public static let special = Self(rawValue: 16)

        /// The flags as bits, one per member above.
        public let rawValue: UInt8

        /// The flags whose bits are set in `rawValue`.
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// The flags from what a file system found out one by one.
        public init(
            isDirectory: Bool = false,
            isSymlink: Bool = false,
            isPackage: Bool = false,
            isHidden: Bool = false,
            isSpecial: Bool = false
        ) {
            self = Self(rawValue: 0)
            if isDirectory { insert(.directory) }
            if isSymlink { insert(.symlink) }
            if isPackage { insert(.package) }
            if isHidden { insert(.hidden) }
            if isSpecial { insert(.special) }
        }
    }

    /// What a file system says about the contents of an entry: its size, the date of its
    /// last change and its permissions.
    public struct Stat: Equatable, Sendable {
        /// The size of the contents in bytes; 0 for a folder.
        public var size: Int64
        /// The date of the last change.
        public var modified: Date
        /// The permission bits (`0o755`).
        public var permissions: UInt16

        /// Nothing in it, never changed (the first second of 1970), readable by all and
        /// writable by its owner, unless said otherwise.
        public init(size: Int64 = 0, modified: Date = Date(timeIntervalSince1970: 0), permissions: UInt16 = 0o644) {
            self.size = size
            self.modified = modified
            self.permissions = permissions
        }
    }

    /// Where an entry has no link target size.
    private static let unknown = Int64.min
    /// What `splitPoint` says for a name without an extension.
    internal static let noExtension = -1

    /// Where the entry is.
    public let url: URL
    /// The entry's name, as the file system gives it (it may differ from the last part of
    /// `url`, for a name that cannot be written in a location).
    public let name: String
    /// What kind of entry it is.
    public let kind: Kind
    /// What the file system says about its contents.
    public let stat: Stat
    /// Folder size calculated with Space; replaces `<DIR>` in the Size column.
    public var computedSize: Int64?
    /// For a link to a regular file: the size of that file; nil for everything else, and
    /// where the file system did not look.
    public var linkTargetSize: Int64? {
        get { targetSize == Self.unknown ? nil : targetSize }
        set { targetSize = newValue ?? Self.unknown }
    }
    /// The one above, kept as a plain number so that a list of a million entries does not
    /// pay for an optional each.
    private var targetSize = Self.unknown

    /// A directory, or a symbolic link that points to one.
    public var isDirectory: Bool { kind.contains(.directory) }
    /// A symbolic link (`isDirectory` too when it points to a directory).
    public var isSymlink: Bool { kind.contains(.symlink) }
    /// A directory that is shown and opened like a file (a macOS bundle such as `.app`).
    public var isPackage: Bool { kind.contains(.package) }
    /// Not shown unless the user asks for hidden entries.
    public var isHidden: Bool { kind.contains(.hidden) }
    /// Neither a file with contents nor a directory: a pipe, a device or a socket, or a link to one.
    ///
    /// Opening it to read may never return, so whoever reads files by the dozen (a search) leaves these out. False
    /// where the file system knows no such things.
    public var isSpecial: Bool { kind.contains(.special) }
    /// The size of the contents in bytes; 0 for a folder.
    public var size: Int64 { stat.size }
    /// The date of the last change.
    public var modified: Date { stat.modified }
    /// The permission bits (`0o755`).
    public var permissions: UInt16 { stat.permissions }

    /// Listed with the folders, in brackets, and entered with Enter.
    public var isFolder: Bool { isDirectory && !isPackage }

    /// A directory that is not a link; operations descend into these and treat links as links.
    public var isRealDirectory: Bool { isDirectory && !isSymlink }

    /// Name column: the name without its extension; folders keep the whole name.
    public var baseName: String { isFolder ? name : Self.split(name).base }

    /// Ext column: the extension without the dot; empty for folders.
    public var ext: String { isFolder ? "" : Self.split(name).ext }

    /// An entry called `name` at `url`; a plain empty file unless `kind` and `stat` say more.
    public init(url: URL, name: String, kind: Kind = [], stat: Stat = Stat(), linkTargetSize: Int64? = nil) {
        self.url = url
        self.name = name
        self.kind = kind
        self.stat = stat
        targetSize = linkTargetSize ?? Self.unknown
    }

    /// Splits at the last dot.
    ///
    /// A leading dot (`.zshrc`) does not start an extension.
    public static func split(_ name: String) -> (base: String, ext: String) {
        // Nearly every name is cut by looking at its bytes: a dot between ASCII neighbours
        // is a character of its own. Only a dot next to other text (it may carry an
        // accent) needs the slow walk over whole characters.
        if case .some(.some(let cut)) = name.utf8.withContiguousStorageIfAvailable(splitPoint) {
            guard cut != noExtension else {
                return (name, "")
            }
            let dot = name.utf8.index(name.utf8.startIndex, offsetBy: cut)
            return (String(name[..<dot]), String(name[name.utf8.index(after: dot)...]))
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// Where `split` cuts a name given as UTF-8: the offset of the dot, or `noExtension`.
    ///
    /// Nil when the bytes alone cannot tell.
    internal static func splitPoint(_ name: UnsafeBufferPointer<UInt8>) -> Int? {
        guard let dot = name.lastIndex(of: 0x2E) else {
            return noExtension
        }
        if dot > 0, name[dot - 1] >= 0x80 {
            return nil
        }
        if dot + 1 < name.count, name[dot + 1] >= 0x80 {
            return nil
        }
        return dot == 0 || dot + 1 == name.count ? noExtension : dot
    }
}
