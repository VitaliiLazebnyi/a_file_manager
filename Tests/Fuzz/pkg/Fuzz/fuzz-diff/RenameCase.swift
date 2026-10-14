import Foundation
import FuzzCore

@testable import MultiRenamePlugin

/// One item for the rename engine, with the dialog's settings and context, read out of a fuzz input.
internal struct RenameCase {
    /// The dialog's settings: masks, search and replace, letter case, counter.
    internal let settings: RenameSettings
    /// The context of the run: the list's size, clock, locale, environment, clipboard.
    internal let context: RenameContext
    /// The item that is renamed.
    internal let subject: RenameSubject
    /// The item's place in the list.
    internal let index: Int
    /// A name given for the item (a renaming list), if any.
    internal let given: String?

    /// The case read from `choices`; `regex` says whether the search is a regular expression.
    internal init(_ choices: inout Choices, regex: Bool) {
        let flags = choices.byte()
        let more = choices.byte()
        var readSettings = Self.settings(flags: flags, regex: regex, choices: &choices)
        var readContext = RenameContext()
        // the number of items in the list: never negative, and no list is longer than a few million
        readContext.count = more & 1 != 0 ? Int(choices.u32() % 3_000_000) : 1 + Int(choices.byte())
        index = more & 2 != 0 ? abs(Self.number(&choices) % 1_000_000) : Int(choices.byte())
        Self.fix(&readContext)
        let date = kRealisticDates[Int(choices.byte()) % kRealisticDates.count]
        readContext.contentDate = Self.contentDate(more: more, date: date)
        let size = Int64(truncatingIfNeeded: Self.number(&choices))
        readSettings.nameMask = text(choices.until(0x0A))
        readSettings.extensionMask = text(choices.until(0x0A))
        readSettings.search = text(choices.until(0x0A))
        readSettings.replacement = text(choices.until(0x0A))
        let name = name255(choices.until(0x0A))
        let directory = text(choices.until(0x0A))
        let clip = choices.until(0x0A)
        readContext.clipboard = more & 16 != 0 ? nil : text(clip).replacingOccurrences(of: "\u{1}", with: "\n")
        let rule = choices.until(0x0A)
        if more & 32 != 0 {
            readContext.titleRule = TitleCaseRule(setting: text(rule))
        }
        given = more & 64 != 0 ? text(choices.until(0x0A)) : nil
        subject = RenameSubject(
            name: name,
            isFolder: more & 128 != 0,
            size: size,
            modified: Date(timeIntervalSince1970: date),
            directoryPath: directory
        )
        self.settings = readSettings
        self.context = readContext
    }

    /// A number for the counter or the index: small, negative, huge, or one of the extremes.
    internal static func number(_ choices: inout Choices) -> Int {
        let kind = choices.byte()
        switch kind % 8 {
        case 0:
            return Int(choices.byte())

        case 1:
            return -Int(choices.byte())

        case 2:
            return Int(truncatingIfNeeded: choices.u64())

        case 3:
            return Int.max

        case 4:
            return Int.min

        case 5:
            return Int(choices.u16())

        default:
            return Int(kind >> 3)
        }
    }

    /// The settings `flags` ask for, with a counter read from `choices`.
    internal static func settings(flags: UInt8, regex: Bool, choices: inout Choices) -> RenameSettings {
        var made = RenameSettings()
        made.caseSensitive = flags & 1 != 0
        made.firstOnly = flags & 2 != 0
        made.searchesExtension = flags & 4 != 0
        made.regularExpression = regex
        made.substitute = flags & 8 != 0
        made.letterCase = LetterCase(rawValue: Int(flags >> 4) % 6) ?? .unchanged
        let start = number(&choices)
        let step = number(&choices)
        let digits = number(&choices)
        made.counter = CounterDefinition(start: start, step: step, digits: digits)
        return made
    }

    /// Sets the clock, locale, time zone and environment, the same for every case.
    internal static func fix(_ context: inout RenameContext) {
        context.opened = Date(timeIntervalSince1970: 1_700_000_000)
        context.changed = Date(timeIntervalSince1970: 1_700_003_600)
        context.locale = kPosixLocale
        context.timeZone = kUTC
        context.environment = ["HOME": "/Users/me", "X": "a:b/c\\d", "E": "", "é": "ü"]
    }

    /// The date inside the file's content: a second after `date`, unknown, or not asked for.
    internal static func contentDate(more: UInt8, date: Double) -> (@Sendable (RenameSubject) -> Date?)? {
        if more & 4 != 0 {
            return { _ in Date(timeIntervalSince1970: date + 1) }
        }
        if more & 8 != 0 {
            return { _ in nil }
        }
        return nil
    }
}
