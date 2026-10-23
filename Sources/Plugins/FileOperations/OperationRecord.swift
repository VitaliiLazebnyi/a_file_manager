/// What a job did to one item, for the operation log (13 › Operation › Log file).
public struct OperationRecord: Sendable {
    /// What was done; the raw value is how the log writes it.
    public enum Verb: String, Sendable {
        /// The source was added to the end of a file at the target.
        case append = "Append"
        /// A file or folder was copied.
        case copy = "Copy"
        /// A file was deleted for good.
        case delete = "Delete"
        /// A folder was created.
        case makeFolder = "New folder"
        /// A file or folder was moved.
        case move = "Move"
        /// An empty file was created.
        case newFile = "New file"
        /// A folder was removed.
        case removeFolder = "Delete folder"
        /// An item got another name where it lies.
        case rename = "Rename"
        /// An item was moved to the Trash.
        case trash = "Move to Trash"
    }

    /// How it ended.
    public enum Status: Equatable, Sendable {
        /// It was done.
        case done
        /// It failed, with this message.
        case failed(String)
        /// The user chose to skip it.
        case skipped
    }

    /// What was done.
    public let verb: Verb
    /// Locations as shown to the user.
    public let source: String
    /// Where it went, as shown to the user; nil for what has no target (a delete, a new folder).
    public let target: String?
    /// How it ended.
    public let status: Status

    /// A record of `verb` done to `source`, by default without a target and done.
    public init(_ verb: Verb, source: String, target: String? = nil, status: Status = .done) {
        self.verb = verb
        self.source = source
        self.target = target
        self.status = status
    }
}
