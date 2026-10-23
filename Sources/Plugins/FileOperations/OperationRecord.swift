/// What a job did to one item, for the operation log (13 › Operation › Log file).
public struct OperationRecord: Sendable {
    public enum Verb: String, Sendable {
        case copy = "Copy"
        case move = "Move"
        case append = "Append"
        case delete = "Delete"
        case trash = "Move to Trash"
        case makeFolder = "New folder"
        case removeFolder = "Delete folder"
        case newFile = "New file"
        case rename = "Rename"
    }

    public enum Status: Equatable, Sendable {
        case done
        case failed(String)
        case skipped
    }

    public let verb: Verb
    /// Locations as shown to the user.
    public let source: String
    public let target: String?
    public let status: Status

    public init(_ verb: Verb, source: String, target: String? = nil, status: Status = .done) {
        self.verb = verb
        self.source = source
        self.target = target
        self.status = status
    }
}
