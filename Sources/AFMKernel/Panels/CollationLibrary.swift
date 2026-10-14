import Foundation

/// The functions of the system's collation library (ICU) that a `NameCollator` uses.
internal struct CollationLibrary {
    /// `ucol_open`: the collator of a language, and an error status.
    internal typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> OpaquePointer?
    /// `ucol_setAttribute`: one setting, and an error status.
    internal typealias SetAttribute = @convention(c) (OpaquePointer, Int32, Int32, UnsafeMutablePointer<Int32>) -> Void
    /// `ucol_getSortKey`: writes the key of UTF-16 text, as far as there is room, and returns
    /// its whole length.
    internal typealias SortKey =
        @convention(c) (OpaquePointer, UnsafePointer<UInt16>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    /// `ucol_close`.
    internal typealias Close = @convention(c) (OpaquePointer) -> Void

    /// The system's library; nil when it cannot be reached.
    internal static let system: Self? = {
        guard let handle = dlopen("/usr/lib/libicucore.A.dylib", RTLD_LAZY),
            let openSymbol = dlsym(handle, "ucol_open"),
            let setAttributeSymbol = dlsym(handle, "ucol_setAttribute"),
            let sortKeySymbol = dlsym(handle, "ucol_getSortKey"),
            let closeSymbol = dlsym(handle, "ucol_close")
        else {
            return nil
        }
        return Self(
            open: unsafeBitCast(openSymbol, to: Open.self),
            setAttribute: unsafeBitCast(setAttributeSymbol, to: SetAttribute.self),
            sortKey: unsafeBitCast(sortKeySymbol, to: SortKey.self),
            close: unsafeBitCast(closeSymbol, to: Close.self)
        )
    }()

    /// Opens a collator.
    internal let open: Open
    /// Changes a setting of a collator.
    internal let setAttribute: SetAttribute
    /// Makes a key.
    internal let sortKey: SortKey
    /// Closes a collator.
    internal let close: Close
}
