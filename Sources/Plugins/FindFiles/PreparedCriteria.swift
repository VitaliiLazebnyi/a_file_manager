public import AFMKernel
import Foundation

/// `FileCriteria` with the ages turned into moments, so a search does the calendar
/// arithmetic once, not for every file.
///
/// Immutable; may be used from several threads.
public struct PreparedCriteria {
    private let criteria: FileCriteria
    private let notOlderCutoff: Date?
    private let olderCutoff: Date?

    /// `criteria` with its ages counted back from `now` in `calendar`.
    internal init(_ criteria: FileCriteria, now: Date, calendar: Calendar) {
        self.criteria = criteria
        notOlderCutoff = criteria.notOlderThan?.cutoff(before: now, calendar: calendar)
        olderCutoff = criteria.olderThan?.cutoff(before: now, calendar: calendar)
    }

    /// Whether `item` passes every criterion that is set.
    public func matches(_ item: FileItem) -> Bool {
        if let dateFrom = criteria.dateFrom, item.modified < dateFrom {
            return false
        }
        if let dateTo = criteria.dateTo, item.modified > dateTo {
            return false
        }
        if let notOlderCutoff, item.modified < notOlderCutoff {
            return false
        }
        if let olderCutoff, item.modified >= olderCutoff {
            return false
        }
        if let size = criteria.size, item.isDirectory || !size.matches(item.size) {
            return false
        }
        return criteria.hidden.accepts(item.isHidden) && criteria.directory.accepts(item.isDirectory)
            && criteria.symbolicLink.accepts(item.isSymlink)
            && criteria.readOnly.accepts(item.permissions & 0o200 == 0)
            && criteria.executable.accepts(item.permissions & 0o111 != 0 && !item.isDirectory)
            && criteria.package.accepts(item.isPackage)
    }
}
