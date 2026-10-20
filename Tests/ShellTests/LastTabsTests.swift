import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Closing the tab whose cursor the list shows: the list forgets that cursor with the tab.
@MainActor
@Suite(.serialized)
internal struct LastTabsTests {
    private let program: PanelProgram

    /// The program's folders: `A` with `docs`, `one.txt`, `two.txt`; `B` with `fresh.txt`.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
    }

    /// The shown tab is closed while the next one has not been read: no cursor is shown, not
    /// the closed tab's.
    @Test
    internal func theCursorOfAClosedTabIsForgotten() async throws {
        let app = await program.start(
            plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard),
            fileSystems: []
        )
        defer { app.stop() }
        let panel = app.left
        await program.settle(app)
        let closing = ObjectIdentifier(panel.model)
        try #require(panel.shownCursor?.tab == closing)
        _ = panel.tabs.insertTab(showing: program.box.url("B"), at: 1, activate: false)
        #expect(panel.tabs.closeTab(at: 0))
        #expect(panel.shownCursor == nil)
    }
}
