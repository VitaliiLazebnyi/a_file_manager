import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// The criteria of the Advanced and Plugins tabs: ages, dates, sizes, attributes and field rules.
@Suite
internal struct SearchCriteriaRules {
    /// What a file of a test is like; what is not said is a plain file `a.txt` of 0 bytes from 1970.
    private struct Traits {
        var name = "a.txt"
        var size: Int64 = 0
        var modified = Date(timeIntervalSince1970: 0)
        var permissions: UInt16 = 0o644
        var directory = false
        var hidden = false
        var symlink = false
        var package = false
    }

    /// The Gregorian calendar in UTC, so that midnight is the same everywhere.
    internal let calendar: Calendar = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        return utc
    }()

    /// Noon of a day of October 2026.
    internal func date(_ day: Int) -> Date {
        date(day, 12)
    }

    /// An hour of a day of October 2026.
    internal func date(_ day: Int, _ hour: Int) -> Date {
        // Every day of October has every hour: the date is always there.
        calendar.date(from: DateComponents(year: 2_026, month: 10, day: day, hour: hour)) ?? .distantPast
    }

    private func file(_ traits: Traits) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/x/" + traits.name),
            name: traits.name,
            kind: .init(
                isDirectory: traits.directory,
                isSymlink: traits.symlink,
                isPackage: traits.package,
                isHidden: traits.hidden
            ),
            stat: .init(size: traits.size, modified: traits.modified, permissions: traits.permissions)
        )
    }

    /// Ages of days and longer reach back to midnight, shorter ones to the minute.
    @Test
    internal func ageCutsOffAtMidnightForDaysAndLonger() {
        let now = date(12, 15)
        #expect(Age(3, .hours).cutoff(before: now, calendar: calendar) == date(12, 12))
        #expect(Age(90, .minutes).cutoff(before: now, calendar: calendar) == now.addingTimeInterval(-5_400))
        #expect(Age(2, .days).cutoff(before: now, calendar: calendar) == date(10, 0))
        #expect(Age(1, .weeks).cutoff(before: now, calendar: calendar) == date(5, 0))
        #expect(
            Age(1, .months).cutoff(before: now, calendar: calendar)
                == calendar.date(from: DateComponents(year: 2_026, month: 9, day: 12))
        )
        #expect(
            Age(1, .years).cutoff(before: now, calendar: calendar)
                == calendar.date(from: DateComponents(year: 2_025, month: 10, day: 12))
        )
    }

    /// "Not older than", "older than" and "date between" hold together, each bound on its own.
    @Test
    internal func dateCriteria() {
        let now = date(12, 15)
        var criteria = FileCriteria(notOlderThan: Age(2, .days))
        #expect(criteria.matches(file(Traits(modified: date(10, 1))), now: now, calendar: calendar))
        #expect(!criteria.matches(file(Traits(modified: date(9, 23))), now: now, calendar: calendar))
        // Older than 2 days but not older than 7: a window.
        criteria = FileCriteria(notOlderThan: Age(7, .days), olderThan: Age(2, .days))
        #expect(criteria.matches(file(Traits(modified: date(7))), now: now, calendar: calendar))
        #expect(!criteria.matches(file(Traits(modified: date(11))), now: now, calendar: calendar))
        #expect(!criteria.matches(file(Traits(modified: date(2))), now: now, calendar: calendar))
        criteria = FileCriteria(dateFrom: date(3, 0), dateTo: date(5, 23))
        #expect(
            criteria.matches(file(Traits(modified: date(4))), now: now)
                && criteria.matches(file(Traits(modified: date(5, 22))), now: now)
        )
        #expect(
            !criteria.matches(file(Traits(modified: date(2))), now: now)
                && !criteria.matches(file(Traits(modified: date(6))), now: now)
        )
        #expect(FileCriteria(dateFrom: date(3)).matches(file(Traits(modified: date(30))), now: now))
        #expect(FileCriteria().isEmpty && !criteria.isEmpty)
    }

    /// Sizes compare in their unit, `=` taking every size that shows as the figure; folders have none.
    @Test
    internal func sizeRules() {
        #expect(SizeRule(.equal, 19).matches(19) && !SizeRule(.equal, 19).matches(20))
        #expect(SizeRule(.greater, 1, .kilobytes).matches(1_025) && !SizeRule(.greater, 1, .kilobytes).matches(1_024))
        #expect(
            SizeRule(.less, 0.5, .megabytes).matches(524_287) && !SizeRule(.less, 0.5, .megabytes).matches(524_288)
        )
        #expect(SizeRule(.equal, 2, .kilobytes).matches(2_048) && SizeRule(.equal, 2, .kilobytes).matches(3_071))
        #expect(!SizeRule(.equal, 2, .kilobytes).matches(3_072) && !SizeRule(.equal, 2, .kilobytes).matches(2_047))
        #expect(
            SizeRule(.greater, 0.1, .gigabytes).matches(107_374_183)
                && !SizeRule(.greater, 0.1, .gigabytes).matches(107_374_182)
        )
        let criteria = FileCriteria(size: SizeRule(.greater, 10))
        #expect(
            criteria.matches(file(Traits(size: 11)), now: Date())
                && !criteria.matches(file(Traits(size: 10)), now: Date())
        )
        // Folders have no size to compare.
        #expect(!criteria.matches(file(Traits(name: "dir", size: 100, directory: true)), now: Date()))
    }

    /// An attribute must be set, must not be set, or does not count.
    @Test
    internal func attributesAreTriState() {
        var criteria = FileCriteria()
        #expect(!criteria.hasAttributes)
        criteria.hidden = .set
        criteria.directory = .unset
        #expect(criteria.hasAttributes)
        #expect(criteria.matches(file(Traits(hidden: true)), now: Date()))
        #expect(
            !criteria.matches(file(Traits()), now: Date())
                && !criteria.matches(file(Traits(directory: true, hidden: true)), now: Date())
        )
        criteria = FileCriteria()
        criteria.readOnly = .set
        criteria.executable = .unset
        #expect(criteria.matches(file(Traits(permissions: 0o444)), now: Date()))
        #expect(
            !criteria.matches(file(Traits(permissions: 0o644)), now: Date())
                && !criteria.matches(file(Traits(permissions: 0o555)), now: Date())
        )
        criteria = FileCriteria()
        (criteria.symbolicLink, criteria.package) = (.set, .unset)
        #expect(
            criteria.matches(file(Traits(symlink: true)), now: Date())
                && !criteria.matches(file(Traits(symlink: true, package: true)), now: Date())
        )
    }

    /// The operators of a rule compare text, case, expressions and numbers with grouping.
    @Test
    internal func fieldRuleOperators() {
        func rule(_ comparison: FieldRule.Operator, _ value: String) -> FieldRule {
            FieldRule("f", comparison, value)
        }
        #expect(rule(.contains, "CAM").matches("TestCam 3") && !rule(.containsCase, "CAM").matches("TestCam 3"))
        #expect(rule(.notContains, "nikon").matches("TestCam") && rule(.notContainsCase, "cam").matches("TestCam"))
        #expect(rule(.equals, "testcam").matches("TestCam") && !rule(.equalsCase, "testcam").matches("TestCam"))
        #expect(
            rule(.notEquals, "x").matches("y") && !rule(.notEquals, "X").matches("x")
                && rule(.notEqualsCase, "X").matches("x")
        )
        #expect(rule(.regex, "^test\\w+$").matches("TestCam") && rule(.notRegex, "^cam").matches("TestCam"))
        #expect(
            rule(.greater, "1000").matches("1,024") && !rule(.greater, "1024").matches("1,024")
                && rule(.greaterOrEqual, "1024").matches("1,024")
        )
        #expect(rule(.less, "9").matches("10") == false && rule(.lessOrEqual, "10").matches("10"))
        // Text is ordered as text; an empty field is neither more nor less.
        #expect(rule(.greater, "apple").matches("Banana") && !rule(.less, "apple").matches(""))
        #expect(FieldRule.Operator.allCases.map(\.title).count == Set(FieldRule.Operator.allCases.map(\.title)).count)
    }

    /// Rules combine with AND or OR; a list switched off passes, a field that is gone never matches.
    @Test
    internal func fieldRulesCombineWithAndOrOr() {
        let fields = [
            "len": SearchField(id: "len", title: "Length") { String($0.name.count) },
            "name": SearchField(id: "name", title: "Name") { $0.name }
        ]
        let rules = [FieldRule("len", .greater, "5"), FieldRule("name", .contains, "b")]
        #expect(
            FieldRules(isEnabled: true, matchAll: true, rules: rules)
                .matches(file(Traits(name: "abcdef")), fields: fields)
        )
        #expect(
            !FieldRules(isEnabled: true, matchAll: true, rules: rules)
                .matches(file(Traits(name: "abc")), fields: fields)
        )
        #expect(
            FieldRules(isEnabled: true, matchAll: false, rules: rules)
                .matches(file(Traits(name: "abc")), fields: fields)
        )
        #expect(
            !FieldRules(isEnabled: true, matchAll: false, rules: rules)
                .matches(file(Traits(name: "xyz")), fields: fields)
        )
        // Switched off, the list is kept but does not count; a field that is gone never matches.
        #expect(FieldRules(isEnabled: false, rules: rules).matches(file(Traits(name: "xyz")), fields: fields))
        #expect(
            !FieldRules(isEnabled: true, rules: [FieldRule("gone", .contains, "")])
                .matches(
                    file(Traits(name: "xyz")),
                    fields: fields
                )
        )
    }
}
