/// What `FileTransferService.transfer` does with the files: copy them, or move them.
public enum TransferKind: Equatable, Sendable {
    /// The files stay where they are, and copies arrive.
    case copy
    /// The files leave where they are.
    case move
}
