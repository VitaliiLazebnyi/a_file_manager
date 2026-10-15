import AFMKernel
import AppKit
import TestSupport

@testable import ViewerPlugin

/// Lister windows on files of a folder of the local disk, with the panels, the links and the
/// clipboard replaced by ones that show nothing and keep what they were given.
@MainActor
internal final class CoverageViewerPaneBench {
    /// The kernel, the panels and the viewer.
    internal let setup: CoverageViewerBench
    /// The folder of the files; removed by `close()`.
    internal let folder: URL
    /// The panels the panes ask with.
    internal let dialogs = CoverageViewerDialogs()
    /// The links the panes would open.
    internal let links = CoverageViewerLinks()
    /// The clipboard of the panes.
    internal let scratch = ScratchPasteboard()

    /// The kernel's answers to questions.
    internal var interaction: ScriptedInteraction { setup.interaction }

    /// The Lister's options.
    internal var settings: ListerSettings { ListerSettings(setup.bench.kernel.settings) }

    /// A bench with an empty folder.
    internal init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "afm-cov-pane-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setup = CoverageViewerBench(left: folder, showsWindows: false)
    }

    /// A file of the folder holding `data`.
    @discardableResult
    internal func file(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A file of the folder holding `text` in UTF-8.
    @discardableResult
    internal func file(_ name: String, text: String) throws -> URL {
        try file(name, Data(text.utf8))
    }

    /// A Lister window on `url`; its pane is returned once the file has been read.
    internal func open(_ url: URL) async -> ViewerPane? {
        setup.plugin.view(url)
        guard let pane = setup.plugin.windows.last?.pane else {
            return nil
        }
        prepare(pane)
        return await setup.wait { pane.loaded != nil || pane.failure != nil } ? pane : nil
    }

    /// Gives `pane` the bench's panels, links and clipboard.
    internal func prepare(_ pane: ViewerPane) {
        pane.dialogs = dialogs
        pane.links = links
        pane.pasteboard = scratch.pasteboard
    }

    /// Waits until the text of `pane` is shown in its mode.
    internal func textShown(_ pane: ViewerPane) async -> Bool {
        await setup.wait {
            pane.pager.document?.layout == pane.layout && !pane.pager.isIndexing && pane.pager.position != nil
        }
    }

    /// Waits until `condition` holds.
    internal func wait(until condition: () -> Bool) async -> Bool {
        await setup.wait(until: condition)
    }

    /// A key press as the window delivers it.
    internal func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )
    }

    /// Closes every window and removes the folder.
    internal func close() {
        setup.plugin.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    deinit {
        // Nothing to release.
    }
}
