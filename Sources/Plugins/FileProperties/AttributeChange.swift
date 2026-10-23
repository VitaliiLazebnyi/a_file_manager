import Foundation

/// Everything the Change Attributes dialog can ask for.
///
/// What is unchanged, nil or `.keep` stays as it is.
internal struct AttributeChange: Equatable {
    /// Reads the parameter words of the command one after the other, collecting the date and time
    /// texts until all of them are read.
    private struct ParameterReader {
        /// What the words read so far ask for, without the date.
        var change = AttributeChange()
        /// The parameters began with `=`.
        var applyAtOnce = false
        /// The date and time texts as the dialog's fields would hold them.
        var date = ""
        var time = ""
        /// A word asked for a new date or time.
        var changesDate = false

        /// Takes one word such as `+h` or `+d2024-05-01`; false when it cannot be read.
        mutating func read(_ word: Substring) -> Bool {
            guard let sign = word.first, sign == "+" || sign == "-", let letter = word.dropFirst().first else {
                return false
            }
            let value = String(word.dropFirst(2))
            if value.isEmpty, readSwitch(letter, isOn: sign == "+") {
                return true
            }
            return readValue(letter, value)
        }

        /// A letter that stands alone: `h`, `r`, `f`, `c`, and Windows' `a` and `s`, which have no
        /// counterpart and are ignored.
        mutating func readSwitch(_ letter: Character, isOn: Bool) -> Bool {
            switch letter {
            case "h":
                change.hidden = isOn ? .set : .clear

            case "r":
                change.locked = isOn ? .set : .clear

            case "f":
                change.recurse = isOn

            case "a", "s":
                break

            case "c":
                // Fills both fields; a later `+t` without a value empties the time again, so
                // that `+c +t` changes the date only.
                (date, time) = TimestampChange.fieldTexts(for: Date(), calendar: .current)
                changesDate = true

            default:
                return false
            }
            return true
        }

        /// A letter followed by its value: `d` date, `t` time, `m` permissions.
        mutating func readValue(_ letter: Character, _ value: String) -> Bool {
            switch letter {
            case "d":
                (date, changesDate) = (value, true)

            case "t":
                (time, changesDate) = (value, true)

            case "m":
                guard let typed = PermissionChange(value) else {
                    return false
                }
                change.permissions = typed

            default:
                return false
            }
            return true
        }

        /// The change with its date, once every word is read; nil when the date or time cannot be read.
        func finished() -> (change: AttributeChange, applyAtOnce: Bool)? {
            var result = change
            if changesDate {
                guard let typed = TimestampChange(date: date, time: time) else {
                    return nil
                }
                result.timestamp = typed
            }
            return (result, applyAtOnce)
        }
    }

    /// The new permissions.
    internal var permissions = PermissionChange.unchanged
    /// The hidden flag (`UF_HIDDEN`); local files only.
    internal var hidden = FlagChange.keep
    /// Finder's Locked (`UF_IMMUTABLE`), the Mac's read-only attribute; local files only.
    internal var locked = FlagChange.keep
    /// The new date of last change.
    internal var timestamp: TimestampChange?
    /// The new owner, by name or number; local files only.
    internal var owner: String?
    /// The new group, by name or number; local files only.
    internal var group: String?
    /// Also change everything inside the folders among the operands.
    internal var recurse = false

    /// Whether the change would leave every item as it is.
    internal var isEmpty: Bool {
        permissions == .unchanged && hidden == .keep && locked == .keep && (timestamp?.changesNothing ?? true)
            && owner == nil && group == nil
    }

    /// Whether the change needs POSIX calls, which only the Mac's own file system answers.
    internal var needsLocalFileSystem: Bool { hidden != .keep || locked != .keep || owner != nil || group != nil }

    /// Reads the parameter text of the command, modelled on `OPENATTRIBUTES` (spec 07 ›
    /// `OPENATTRIBUTES`): `+h`/`-h` hidden, `+r`/`-r` locked (read only), `+f`/`-f` recurse,
    /// `+d<date>`, `+t<time>`, `+c` current date and time, and for the Mac `+m<permissions>`.
    ///
    /// A leading `=` means "apply without showing the dialog". Windows' `a` and `s` have no
    /// counterpart and are ignored. Nil when a token cannot be read.
    internal static func parse(parameters: String) -> (change: Self, applyAtOnce: Bool)? {
        var reader = ParameterReader()
        for (index, word) in parameters.split(separator: " ").enumerated() {
            if index == 0, word.hasPrefix("=") {
                reader.applyAtOnce = true
                if word.count == 1 { continue }
            }
            guard reader.read(word.hasPrefix("=") ? word.dropFirst() : word) else {
                return nil
            }
        }
        return reader.finished()
    }
}
