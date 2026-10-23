/// What a symbolic link leads to.
internal struct LinkTarget {
    /// The link leads to a folder.
    internal var isDirectory: Bool
    /// The link leads to a regular file.
    internal var isRegular: Bool
    /// The size of the target when it is a regular file.
    internal var size: Int64

    /// The link leads to neither a folder nor a regular file (a pipe, a device, a socket).
    internal var isSpecial: Bool { !isDirectory && !isRegular }
}
