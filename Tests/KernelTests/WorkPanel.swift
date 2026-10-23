import AFMKernel
import TestSupport

/// A panel model showing `/work` of a memory file system: the folders `bin` and `docs`, the files `a.txt` (2 KB) and
/// `b.md` (1 KB), and the hidden `.hidden`.
///
/// Main thread only.
@MainActor
internal final class WorkPanel {
    /// The file system that holds `/work`.
    internal let memory = MemoryFileSystem()
    /// The registry the panel's listings are read through.
    internal let fileSystems = FileSystemRegistry()
    /// The panel model, showing `/work`.
    internal let panel: PanelModel

    /// Fills the file system and shows `/work`; throws only when reading it fails.
    internal init() throws {
        memory.addDirectory("/work/docs")
        memory.addDirectory("/work/bin")
        memory.addFile("/work/a.txt", String(repeating: "a", count: 2_048))
        memory.addFile("/work/b.md", String(repeating: "b", count: 1_024))
        memory.addFile("/work/.hidden")
        fileSystems.register(memory)
        panel = PanelModel(directory: memory.url("/work"))
        try show("/work")
    }

    /// The listing of `path` as the panel would read it now (hidden files as the panel shows them).
    internal func listing(_ path: String) throws -> Listing {
        try PanelLoader.load(memory.url(path), showHidden: panel.showHidden, fileSystems: fileSystems).listing
    }

    /// Shows `path`, recorded in the history, the cursor on the first row.
    internal func show(_ path: String) throws {
        try show(path, focus: nil, history: .record)
    }

    /// Shows `path` with the history changed as `history` says.
    internal func show(_ path: String, history: PanelModel.HistoryEffect) throws {
        try show(path, focus: nil, history: history)
    }

    /// Shows `path` with the cursor on `focus` and the history changed as `history` says.
    internal func show(_ path: String, focus: String?, history: PanelModel.HistoryEffect) throws {
        panel.show(try listing(path), focus: focus, history: history)
    }

    deinit {
        // Nothing to release.
    }
}
