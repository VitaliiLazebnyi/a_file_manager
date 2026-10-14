import Foundation

/// How sizes, dates, speeds and attributes are written everywhere in the program
/// (spec 03 › Data formats).
public enum Format {
    /// Day, month, year and time in the order and with the separators of the user's region
    /// (`10/11/2026 01:19` in the US, `11.10.2026 01:19` in Germany).
    ///
    /// One formatter serves every thread (formatting with a `DateFormatter` is safe from
    /// several threads at once; changing one is not, so this one is never changed after it
    /// is made). When the user changes the region or the time zone while the program runs,
    /// it is thrown away and the next date makes a new one: a formatter keeps the pattern it
    /// worked out for the region it was made in.
    private final class Dates {
        private let lock = NSLock()
        private var formatter: DateFormatter?
        private var observers: [any NSObjectProtocol] = []

        init() {
            let names = [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    self?.forget()
                }
            }
        }

        private func forget() {
            lock.lock()
            formatter = nil
            lock.unlock()
        }

        func string(from date: Date) -> String {
            lock.lock()
            let current: DateFormatter
            if let formatter {
                current = formatter
            } else {
                current = DateFormatter()
                current.locale = .current
                current.timeZone = .current
                current.setLocalizedDateFormatFromTemplate("ddMMyyyy HHmm")
                formatter = current
            }
            lock.unlock()
            return current.string(from: date)
        }
    }

    private static let dates = Dates()

    /// `250,944`. Safe on any thread: the digits are grouped here, with no formatter shared
    /// between threads.
    public static func bytes(_ value: Int64) -> String {
        let digits = Array(String(value.magnitude).utf8)
        var text: [UInt8] = []
        text.reserveCapacity(digits.count + digits.count / 3 + 1)
        if value < 0 { text.append(0x2D) }
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { text.append(0x2C) }
            text.append(digit)
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// Status-line unit: `3,607 k`. Any number is a size here (the sizes of an archive or a
    /// server are whatever it says), the largest included.
    public static func kilobytes(_ value: Int64) -> String {
        // Rounded to the nearest, without a sum that could leave the range of a number.
        let (whole, rest) = value.quotientAndRemainder(dividingBy: 1_024)
        return bytes(whole + (rest >= 512 ? 1 : (rest < -512 ? -1 : 0))) + " k"
    }

    /// Counter-strip and drive-line unit: `15 b`, `6.68 k`, `11.06 M`
    public static func shortSize(_ value: Int64) -> String {
        let units = ["k", "M", "G", "T"]
        guard value >= 1_024 else { return "\(value) b" }
        var amount = Double(value) / 1_024
        var unit = 0
        while amount >= 1_024, unit < units.count - 1 {
            amount /= 1_024
            unit += 1
        }
        return String(format: "%.2f %@", amount, units[unit])
    }

    /// Transfer speed: `11.06 M/s`
    public static func speed(_ bytesPerSecond: Double) -> String {
        // A speed measured over no time at all is not a number; it is shown as none.
        shortSize(bytesPerSecond.isFinite ? Int64(max(0, min(bytesPerSecond.rounded(), 9e18))) : 0) + "/s"
    }

    /// A time estimate, coarser the longer it is: `8 s`, `1 min 20 s`, `2 h 05 min`.
    public static func duration(_ seconds: TimeInterval) -> String {
        // An estimate from a speed of zero is endless or no number at all: shown as very long.
        let total = seconds.isFinite ? Int(max(0, min(seconds.rounded(.up), 1e12))) : Int(1e12)
        if total < 60 { return "\(max(total, 1)) s" }
        // Above a minute the seconds are shown in steps of five, so the figure stays calm.
        let stepped = (total + 4) / 5 * 5
        if stepped < 3_600 {
            return stepped % 60 == 0 ? "\(stepped / 60) min" : "\(stepped / 60) min \(stepped % 60) s"
        }
        let minutes = (total + 59) / 60
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// The date and time of last change, as shown in the Date column.
    public static func date(_ value: Date) -> String {
        dates.string(from: value)
    }

    /// The Attr column. macOS has no `r a h s` flags, so it shows the permissions: `rwxr-xr-x`.
    public static func permissions(_ mode: UInt16) -> String {
        let letters: [Character] = ["r", "w", "x"]
        var text = ""
        for bit in 0..<9 {
            text.append(mode & (0o400 >> UInt16(bit)) != 0 ? letters[bit % 3] : "-")
        }
        return text
    }

    /// A name or path that comes from outside (a file name, a server's answer), safe to show
    /// in a message: characters that would mislead are written out as `<U+202E>`. Those are
    /// the control characters (line breaks among them, so the text stays on its line), the
    /// line and paragraph separators, characters without width, and the marks, overrides and
    /// isolates that change the direction of writing (with which `exe.txt` can be made to
    /// read `txt.exe`). The joiners that pictures and some scripts are written with stay.
    public static func displayName(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isMisleading) else { return text }
        var shown = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isMisleading(scalar) {
                shown.append(contentsOf: "<U+\(String(format: "%04X", scalar.value))>".unicodeScalars)
            } else {
                shown.append(scalar)
            }
        }
        return String(shown)
    }

    /// The same, cut to at most `limit` characters with `…` for the rest: for a log line or
    /// a message that must stay short whatever the name is.
    public static func displayName(_ text: String, limit: Int) -> String {
        let limit = max(limit, 0)
        var cut = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            guard count < limit else { return displayName(String(cut)) + "…" }
            cut.append(scalar)
            count += 1
        }
        return displayName(text)
    }

    private static func isMisleading(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x2028, 0x2029: return true
        case 0x200B, 0x200E, 0x200F, 0x2060...0x2064, 0xFEFF, 0x061C: return true
        case 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }
}
