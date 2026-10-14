public import AFMKernel
public import Foundation

/// Services plugins offer each other through `Kernel.services`. The protocols live here, so
/// the plugin that offers one and the plugins that use it share only this module.

public enum TransferKind: Equatable, Sendable {
    case copy, move
}

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

/// Showing a list of files from anywhere as if it were a folder (spec 09 › Feed to listbox,
/// 03 › Branch view). Offered by the plugin that provides such virtual folders; used, for
/// example, by Find Files.
@MainActor
public protocol FileListService {
    /// Shows `files` in `panel` under `title`. The entries keep their real locations, so every
    /// operation works on the files themselves.
    func show(_ files: [URL], title: String, in panel: any PanelHandle)
    /// The same for a caller that knows its list holds no location twice (`isUnique`): the
    /// service then need not look for doubles, which for a list of millions is work worth
    /// saving. The default ignores the word and is `show(_:title:in:)`.
    func show(_ files: [URL], title: String, in panel: any PanelHandle, isUnique: Bool)
}

extension FileListService {
    public func show(_ files: [URL], title: String, in panel: any PanelHandle, isUnique _: Bool) {
        show(files, title: title, in: panel)
    }
}

/// Viewing a file in the built-in viewer. Offered by the viewer plugin; used by plugins that
/// produce something to look at (a comparison, a log).
@MainActor
public protocol ViewerService {
    /// Opens a viewer window for the file at `url`, on any file system.
    func view(_ url: URL)
    /// Opens a viewer window for a text that is not a file.
    func view(text: String, title: String)
}
