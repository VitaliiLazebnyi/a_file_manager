public import Foundation

/// What is carried over when a file is copied from one file system to another.
public struct FileAttributes: Sendable {
    public var modified: Date?
    public var permissions: UInt16?

    public init(modified: Date? = nil, permissions: UInt16? = nil) {
        self.modified = modified
        self.permissions = permissions
    }
}
