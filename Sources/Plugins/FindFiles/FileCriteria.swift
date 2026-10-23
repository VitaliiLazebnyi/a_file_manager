public import AFMKernel
public import Foundation

/// The criteria of the Advanced tab except the duplicate finder; all that are set must hold
/// (spec 09 › Advanced tab).
///
/// The Windows attributes are replaced by what a Mac's files have.
public struct FileCriteria: Codable, Equatable, Sendable {
    /// "Date between", the first moment that counts; nil: no lower bound.
    public var dateFrom: Date?
    /// "Date between", the last moment that counts; nil: no upper bound.
    public var dateTo: Date?
    /// Only files modified within this time before the search started.
    public var notOlderThan: Age?
    /// Only files modified longer ago than this before the search started.
    public var olderThan: Age?
    /// Only files have a size to compare; with a size rule, folders are not found.
    public var size: SizeRule?
    /// The item is hidden, as the panels tell it (`FileItem.isHidden`).
    public var hidden = TriState.any
    /// The item is a folder.
    public var directory = TriState.any
    /// The item is a symbolic link.
    public var symbolicLink = TriState.any
    /// The owner may not write.
    public var readOnly = TriState.any
    /// Somebody may execute it.
    public var executable = TriState.any
    /// A folder shown as a file, such as an application.
    public var package = TriState.any

    /// Whether no criterion is set: every item passes.
    public var isEmpty: Bool { self == Self() }
    /// Whether one of the attribute boxes asks for something.
    public var hasAttributes: Bool {
        [hidden, directory, symbolicLink, readOnly, executable, package].contains { $0 != .any }
    }

    /// The criteria with the given dates, ages and size, and no attribute asked for.
    public init(
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        notOlderThan: Age? = nil,
        olderThan: Age? = nil,
        size: SizeRule? = nil
    ) {
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.notOlderThan = notOlderThan
        self.olderThan = olderThan
        self.size = size
    }

    /// The criteria with the moments worked out once, for testing many files. `nil` when no
    /// criterion is set.
    public func prepared(now: Date, calendar: Calendar = .current) -> PreparedCriteria? {
        isEmpty ? nil : PreparedCriteria(self, now: now, calendar: calendar)
    }

    /// Whether `item` passes; `now` is the moment the search started, so every file is measured against
    /// the same.
    public func matches(_ item: FileItem, now: Date, calendar: Calendar = .current) -> Bool {
        PreparedCriteria(self, now: now, calendar: calendar).matches(item)
    }
}
