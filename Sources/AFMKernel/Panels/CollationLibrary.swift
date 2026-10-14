import Darwin

/// The functions of the system's collation library (ICU) that a `NameCollator` uses.
internal struct CollationLibrary {
    /// `ucol_open`: the collator of a language, and an error status.
    internal typealias Open = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>) -> OpaquePointer?
    /// `ucol_setAttribute`: one setting, and an error status.
    internal typealias SetAttribute = @convention(c) (OpaquePointer, Int32, Int32, UnsafeMutablePointer<Int32>) -> Void
    /// `ucol_getSortKey`: writes the key of UTF-16 text, as far as there is room, and returns
    /// its whole length.
    internal typealias SortKey =
        @convention(c) (OpaquePointer, UnsafePointer<UInt16>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    /// `ucol_close`.
    internal typealias Close = @convention(c) (OpaquePointer) -> Void

    /// The system's library; nil when it cannot be reached.
    internal static let system = load("/usr/lib/libicucore.A.dylib")

    /// Opens a collator.
    internal let open: Open
    /// Changes a setting of a collator.
    internal let setAttribute: SetAttribute
    /// Makes a key.
    internal let sortKey: SortKey
    /// Closes a collator.
    internal let close: Close

    /// The library at `path`; nil when it cannot be loaded or lacks a function.
    internal static func load(_ path: String) -> Self? {
        guard let handle = dlopen(path, RTLD_LAZY) else {
            return nil
        }
        let names = ["ucol_open", "ucol_setAttribute", "ucol_getSortKey", "ucol_close"]
        let symbols = names.compactMap { dlsym(handle, $0) }
        guard symbols.count == names.count else {
            return nil
        }
        return Self(
            open: unsafeBitCast(symbols[0], to: Open.self),
            setAttribute: unsafeBitCast(symbols[1], to: SetAttribute.self),
            sortKey: unsafeBitCast(symbols[2], to: SortKey.self),
            close: unsafeBitCast(symbols[3], to: Close.self)
        )
    }
}
