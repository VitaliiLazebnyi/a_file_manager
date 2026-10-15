import AFMKernel
import Foundation
import OSLog

/// What this process logged under the program's subsystem.
internal enum CoreLogged {
    /// The entries of one category from about `start` on.
    ///
    /// The store's times are coarser than `Date`'s: a second earlier is asked for, and every test
    /// looks for text of its own.
    internal static func entries(in category: String, since start: Date) throws -> [OSLogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        return try store.getEntries(at: store.position(date: start.addingTimeInterval(-1)))
            .filter { entry in
                guard let payload = entry as? any OSLogEntryWithPayload else {
                    return false
                }
                return payload.subsystem == Log.subsystem && payload.category == category
            }
    }

    /// The messages of one category from about `start` on.
    internal static func messages(in category: String, since start: Date) throws -> [String] {
        try entries(in: category, since: start).compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
    }

    /// The faults the kernel logged from about `start` on that contain `text`.
    internal static func faults(containing text: String, since start: Date) throws -> [String] {
        try entries(in: "Kernel", since: start).compactMap { $0 as? OSLogEntryLog }
            .filter { $0.level == .fault && $0.composedMessage.contains(text) }
            .map(\.composedMessage)
    }
}
