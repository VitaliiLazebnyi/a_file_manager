public import Foundation

/// The settings of a log: what goes into it, and when it starts a new file.
extension OperationLog {
    /// When the log starts a new file and keeps the old one under a dated or numbered name.
    public enum Rotation: Equatable, Sendable {
        /// One file for ever.
        case never
        /// A new file with the first line written after midnight.
        case daily
        /// A new file when the log would grow beyond this many bytes.
        case size(Int)
    }

    /// What the Log file page of the configuration holds.
    public struct Configuration: Equatable, Sendable {
        /// Whether anything is logged at all.
        public var isEnabled = false
        /// The log file; rotated copies are put next to it.
        public var file = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Logs/A File Manager/operations.log"
            )
        /// Whether copies, moves, appends, renames and new files are logged.
        public var logsTransfers = true
        /// Whether deletions, to the Trash or for good, are logged.
        public var logsDeletes = true
        /// Whether folders that are created or removed are logged.
        public var logsFolders = true
        /// Whether what succeeded is logged.
        public var logsSuccess = true
        /// Whether what failed is logged, with the error.
        public var logsErrors = true
        /// Whether what the user chose to skip is logged.
        public var logsSkipped = true
        /// When a new file is started.
        public var rotation = Rotation.never
        /// How many rotated copies are kept; 0 keeps all.
        public var keepCount = 30

        /// The page's defaults: off, everything logged once it is on, one file for ever, 30 copies kept.
        public init() {
            // Every setting has its default.
        }

        /// Whether a record is of a kind the user wants in the log.
        public func wants(_ record: OperationRecord) -> Bool {
            wants(record.verb, record.status)
        }

        /// The same, asked before the record is made.
        public func wants(_ verb: OperationRecord.Verb, _ status: OperationRecord.Status) -> Bool {
            let kind: Bool
            switch verb {
            case .copy, .move, .append, .rename, .newFile:
                kind = logsTransfers

            case .delete, .trash:
                kind = logsDeletes

            case .makeFolder, .removeFolder:
                kind = logsFolders
            }
            switch status {
            case .done:
                return kind && logsSuccess

            case .failed:
                return kind && logsErrors

            case .skipped:
                return kind && logsSkipped
            }
        }
    }
}
