import AFMKernel
public import Foundation

/// Copying and moving files with the usual progress window and questions.
/// Offered by the file-operations plugin; used, for example, by the clipboard.
@MainActor
public protocol FileTransferService {
    /// Transfers `sources` into `directory` under their own names. With `renamingSelfCopies`,
    /// a copy into the folder it already is in gets a new name (`report (2).txt`) instead of
    /// being refused. The panels showing the folders involved are re-read when it ends, and
    /// `completion` receives the location of the last item that arrived.
    func transfer(
        _ kind: TransferKind,
        _ sources: [URL],
        into directory: URL,
        renamingSelfCopies: Bool,
        completion: @escaping @MainActor (_ lastTarget: URL?) -> Void
    )
}
