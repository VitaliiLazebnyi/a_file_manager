public import AFMContracts

public enum JobKind: Equatable, Sendable {
    case transfer(TransferKind)
    case delete(toTrash: Bool)

    public static let copy = Self.transfer(.copy)
    public static let move = Self.transfer(.move)
}
