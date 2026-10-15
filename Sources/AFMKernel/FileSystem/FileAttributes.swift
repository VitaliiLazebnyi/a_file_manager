public import Foundation

/// What is carried over when a file is copied from one file system to another.
public struct FileAttributes: Sendable {
    /// The date of last change to give the copy; nil leaves it as it is.
    public var modified: Date?
    /// The permission bits to give the copy (`0o644`); nil leaves them as they are.
    public var permissions: UInt16?

    /// Attributes that change only what is given.
    public init(modified: Date? = nil, permissions: UInt16? = nil) {
        self.modified = modified
        self.permissions = permissions
    }
}
