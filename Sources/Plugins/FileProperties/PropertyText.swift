import AFMContracts
import AFMKernel
import Foundation

/// How the plugin's dialogs and messages write names, modes, sizes and dates.
internal enum PropertyText {
    /// A name as messages show it: line breaks, direction overrides and characters without
    /// width are written out (`<U+202E>`), so a name cannot make a message say something else.
    internal static func shown(_ text: String) -> String {
        Format.displayName(text)
    }

    /// `755`; with set-user-ID, set-group-ID or sticky, four digits.
    internal static func octal(_ mode: UInt16) -> String {
        let text = String(mode & 0o7777, radix: 8)
        return String(repeating: "0", count: max(0, 3 - text.count)) + text
    }

    /// `1,234 bytes (1.21 k)`.
    internal static func size(_ bytes: Int64) -> String {
        "\(Format.bytes(bytes)) bytes" + (bytes >= 1_024 ? " (\(Format.shortSize(bytes)))" : "")
    }

    /// "Sunday, October 11, 2026 at 1:19:22 AM", as a property sheet writes dates.
    internal static func longDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
