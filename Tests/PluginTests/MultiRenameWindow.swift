import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// The window itself: built without being shown, to see that it holds together.
@MainActor
@Suite
internal struct MultiRenameWindow {
    /// The window shows the session's list and fields and follows its changes.
    @Test
    internal func windowShowsTheSessionAndFollowsIt() throws {
        _ = NSApplication.shared
        let memory = MemoryFileSystem()
        memory.addFile("/w/a.txt")
        memory.addFile("/w/b.txt")
        let box = try Sandbox()
        let bench = TestBench(plugins: [], fileSystems: [memory], left: memory.url("/w"), right: memory.url("/w"))
        let session = MultiRenameSession(
            kernel: bench.kernel,
            items: bench.left.model.items,
            store: RenameStore(settings: bench.kernel.settings),
            settings: .unchanged,
            logDirectory: box.url("log"),
            previewsInBackground: false,
            clipboard: { nil },
            clipboardChangeCount: nil
        )
        let controller = MultiRenameWindowController(kernel: bench.kernel, session: session)
        let window = try #require(controller.window)
        #expect(window.title == "Multi-Rename Tool")
        func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
            guard let view else {
                return []
            }
            return ([view as? View].compactMap(\.self)) + view.subviews.flatMap { views(type, in: $0) }
        }
        let table = try #require(views(NSTableView.self, in: window.contentView).first)
        #expect(
            table.numberOfRows == 2
                && table.tableColumns.map(\.title) == ["Old name", "Ext.", "New name", "Size", "Date", "Location"]
        )
        #expect(views(NSButton.self, in: window.contentView).map(\.title).contains("Start!"))
        // A change of the session shows in the fields and in the list.
        session.settings.nameMask = "x[C]"
        #expect(views(NSComboBox.self, in: window.contentView).first?.stringValue == "x[C]")
        let cell = table.view(atColumn: 2, row: 1, makeIfNecessary: true) as? NSTextField
        #expect(cell?.stringValue == "x2.txt")
        session.remove([0])
        #expect(table.numberOfRows == 1)
        controller.close()
    }
}
