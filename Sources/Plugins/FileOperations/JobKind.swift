public import AFMContracts

/// What a job does with its sources: copy or move them to a target, or delete them.
public enum JobKind: Equatable, Sendable {
    /// Away for good, or to the Trash.
    case delete(toTrash: Bool)
    /// A copy or a move to the job's target.
    case transfer(TransferKind)

    /// A copy.
    public static let copy = Self.transfer(.copy)
    /// A move.
    public static let move = Self.transfer(.move)
}
