public import AFMKernel
public import Foundation

/// Showing a list of files from anywhere as if it were a folder (spec 09 › Feed to listbox, 03 › Branch view).
///
/// Offered by the plugin that provides such virtual folders; used, for example, by Find Files.
@preconcurrency
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

/// What a list service need not offer itself.
extension FileListService {
    /// Shows `files` as `show(_:title:in:)` does: a service that cannot make use of
    /// `isUnique` need not offer more.
    public func show(_ files: [URL], title: String, in panel: any PanelHandle, isUnique _: Bool) {
        show(files, title: title, in: panel)
    }
}
