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
        _ kind: TransferKind, _ sources: [URL], into directory: URL, renamingSelfCopies: Bool,
        completion: @escaping @MainActor (_ lastTarget: URL?) -> Void)
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

/// Telling the plugin that connects to servers which addresses the user chose in person.
/// Offered by the network plugin; called by whoever takes a location from the keyboard (the
/// command line, the path field), and by nobody for a location that was read from a file (a
/// tab file, a list, a link, a dropped item): for those the user is asked before the first
/// login to a server that is not a saved connection.
@MainActor
public protocol ServerConsentService {
    /// The user typed this location just now. Main thread.
    func userChose(_ location: URL)
}

extension Kernel {
    /// Says that the user typed `text` as a place just now, in the field of a dialog or of a
    /// window: if it names a server by its address, that server is the user's own choice and
    /// is not asked about ("Connect to X?") when it is first reached. Whoever reads a place
    /// from the keyboard calls this with what was typed, before the place is used.
    ///
    /// `proposal` is what the program had put into the field: text that was left as it was
    /// has not been typed (it may stand for a place that came out of a file), and nothing is
    /// said for it. Nothing is said either for text without an address in it (`scheme://`),
    /// which is every ordinary path: those cost one look at the text. Main thread.
    public func userTyped(location text: String, proposal: String? = nil, relativeTo base: URL) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text != proposal?.trimmingCharacters(in: .whitespaces), text.contains("://"),
            let consent = services.find((any ServerConsentService).self)
        else { return }
        consent.userChose(fileSystems.location(from: text, relativeTo: base))
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
