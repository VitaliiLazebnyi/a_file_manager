@testable import AFMKernel

/// A collation library that stands in for ICU.
///
/// It reaches what the real one never does: a key that does not fit, one that is too long, none
/// at all, a collator that cannot be made. What a collator does is chosen by its identifier, and
/// kept in its handle.
internal enum PanelsFakeCollationLibrary {
    /// What a collator of the fake library does, by identifier.
    internal static let modes = ["plain": 1, "grow": 2, "empty": 3, "huge": 5, "tight": 6, "status": 7, "dotless": 8]

    /// Opens a collator of a known mode.
    internal static let open: CollationLibrary.Open = { identifier, _ in
        let name = identifier.map { String(cString: $0) } ?? "plain"
        return Self.modes[name].flatMap { OpaquePointer(bitPattern: $0) }
    }

    /// Fails the settings of a collator of the `status` mode.
    internal static let setAttribute: CollationLibrary.SetAttribute = { handle, _, _, status in
        if Int(bitPattern: UnsafeRawPointer(handle)) == 7 { status.pointee = 1 }
    }

    /// The key of a text: its UTF-16 units' low bytes, or as the mode wants it.
    internal static let sortKey: CollationLibrary.SortKey = { handle, text, count, buffer, room in
        let mode = Int(bitPattern: UnsafeRawPointer(handle))
        let units = UnsafeBufferPointer(start: text, count: Int(count))
        var length = Int(count)
        switch mode {
        case 2:
            length = 300

        case 3:
            length = 0

        case 5:
            length = 70_000

        case 6:
            length = Int(room) + 1

        case 8:
            length = units.first == 0x2E ? 0 : Int(count)

        default:
            break
        }
        if length <= Int(room), let buffer {
            for index in 0..<length {
                buffer[index] = UInt8(truncatingIfNeeded: units.isEmpty ? 0 : units[index % units.count])
            }
        }
        return Int32(length)
    }

    /// Closes nothing.
    internal static let close: CollationLibrary.Close = { _ in
        // Nothing was opened.
    }

    /// The library.
    internal static let library = CollationLibrary(
        open: open,
        setAttribute: setAttribute,
        sortKey: sortKey,
        close: close
    )

    /// A collator of a mode.
    internal static func collator(_ mode: String) -> NameCollator {
        NameCollator(identifier: mode, numeric: false, library: library)
    }
}
