import AFMKernel
import Foundation

/// A predefined selection type: a mask with further conditions, saved under a name and used
/// in Select group as `>name` (spec 03 › Select and unselect group, 18 › File masks and
/// selection types).
///
/// Total Commander saves a whole search here; this holds what a file list knows of its entries:
/// kind, size, date of last change, hidden and link.
internal struct SelectionType: Codable, Equatable {
    /// Which kind of entry the type takes; the raw value is the one saved and the place in the dialog's list.
    internal enum Kind: Int, Codable {
        /// Files and folders alike.
        case any = 0
        /// Files only.
        case files = 1
        /// Folders only.
        case folders = 2
    }

    /// A condition on a yes/no property; the raw value is the one saved and the place in the dialog's list.
    internal enum Tri: Int, Codable {
        /// The property does not matter.
        case any = 0
        /// Only entries without the property pass.
        case excluded = 2
        /// Only entries with the property pass.
        case required = 1

        /// Whether an entry whose property is `value` passes.
        internal func accepts(_ value: Bool) -> Bool { self == .any || (self == .required) == value }
    }

    /// The name the type is saved and used under (`>name`), compared without regard to case.
    internal var name: String
    /// The file mask the names have to match first, in the syntax of Select group.
    internal var mask = "*.*"
    /// Whether files, folders or both are taken.
    internal var kind = Kind.any
    /// The smallest size in bytes, if any.
    ///
    /// Size limits are asked of files only, and a folder never passes them.
    internal var minSize: Int64?
    /// The largest size in bytes, if any; like `minSize`, a folder never passes it.
    internal var maxSize: Int64?
    /// The earliest date of last change that passes, if any.
    internal var modifiedFrom: Date?
    /// The latest date of last change that passes, if any.
    internal var modifiedTo: Date?
    /// Changed within the last so many days, counted back from the moment of selecting.
    internal var notOlderThanDays: Int?
    /// The condition on the hidden flag.
    internal var hidden = Tri.any
    /// The condition on being a symbolic link.
    internal var links = Tri.any

    // MARK: Text forms of the dialog

    /// `1500`, `10k`, `1.5 M`, `2g`; nil for anything else.
    internal static func size(from text: String) -> Int64? {
        var digits = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !digits.isEmpty else {
            return nil
        }
        var factor = 1.0
        if let unit = digits.last, let power = ["b": 0, "k": 1, "m": 2, "g": 3, "t": 4][unit] {
            factor = pow(1_024, Double(power))
            digits = String(digits.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard let number = Double(digits.replacingOccurrences(of: ",", with: "")), number >= 0 else {
            return nil
        }
        // `1e30` or `inf` is a size larger than any file, not a crash.
        let bytes = number * factor
        return bytes.isFinite && bytes < 9.2e18 ? Int64(bytes) : Int64.max
    }

    /// The text form of a size for the dialog: `10k`, `2M`, `1G` when the size is a whole number of
    /// such units, else the bytes; empty for no size.
    internal static func text(ofSize size: Int64?) -> String {
        guard let size else {
            return ""
        }
        for (unit, power) in [("G", 3), ("M", 2), ("k", 1)] {
            let factor = Int64(pow(1_024, Double(power)))
            if size >= factor, size.isMultiple(of: factor) {
                return "\(size / factor)\(unit)"
            }
        }
        return String(size)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// `2026-10-11` or `2026-10-11 09:58`.
    ///
    /// A day without a time means its start, or with `endOfDay` its last second, so that "to
    /// 2026-10-11" includes that day.
    internal static func date(from text: String, endOfDay: Bool) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = formatter("yyyy-MM-dd HH:mm").date(from: trimmed) {
            return date
        }
        guard let day = formatter("yyyy-MM-dd").date(from: trimmed) else {
            return nil
        }
        return endOfDay ? day.addingTimeInterval(86_399) : day
    }

    /// The text form of a date for the dialog, `2026-10-11 09:58`; empty for no date.
    internal static func text(ofDate date: Date?) -> String {
        date.map(formatter("yyyy-MM-dd HH:mm").string(from:)) ?? ""
    }

    /// The conditions beyond the mask; `now` is the moment the age in days is counted back from.
    internal func accepts(_ item: FileItem, now: Date) -> Bool {
        guard acceptsKind(of: item), acceptsSize(of: item) else {
            return false
        }
        return acceptsDate(of: item, now: now) && hidden.accepts(item.isHidden) && links.accepts(item.isSymlink)
    }

    /// Whether the entry is of the kind the type takes.
    private func acceptsKind(of item: FileItem) -> Bool {
        switch kind {
        case .any:
            true

        case .files:
            !item.isFolder

        case .folders:
            item.isFolder
        }
    }

    /// Whether the entry is within the size limits; with a limit set, a folder never is.
    private func acceptsSize(of item: FileItem) -> Bool {
        guard minSize != nil || maxSize != nil else {
            return true
        }
        guard !item.isFolder else {
            return false
        }
        if let minSize, item.size < minSize {
            return false
        }
        if let maxSize, item.size > maxSize {
            return false
        }
        return true
    }

    /// Whether the date of last change is within the dates and the age in days.
    private func acceptsDate(of item: FileItem, now: Date) -> Bool {
        if let modifiedFrom, item.modified < modifiedFrom {
            return false
        }
        if let modifiedTo, item.modified > modifiedTo {
            return false
        }
        if let notOlderThanDays, item.modified < now.addingTimeInterval(-Double(notOlderThanDays) * 86_400) {
            return false
        }
        return true
    }
}
