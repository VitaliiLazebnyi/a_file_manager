import Foundation

/// The date and time formats one preview uses.
///
/// Built once and shared by the preview threads (formatting with a `DateFormatter` is safe from
/// several threads).
///
/// Unchecked `Sendable`: nothing changes after `init`, and the formatters are only used to format.
internal final class RenameFormats: @unchecked Sendable {
    /// The Gregorian calendar in the time zone of the preview.
    internal let calendar: Calendar
    /// `[d]`: the short date of the locale.
    internal let date: DateFormatter
    /// `[t]`: the medium time of the locale.
    internal let time: DateFormatter

    /// The formats of `locale`, in `timeZone`.
    internal init(locale: Locale, timeZone: TimeZone) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        calendar = gregorian
        date = DateFormatter()
        date.locale = locale
        date.timeZone = timeZone
        date.dateStyle = .short
        date.timeStyle = .none
        time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.dateStyle = .none
        time.timeStyle = .medium
    }

    deinit {
        // Nothing to release.
    }
}
