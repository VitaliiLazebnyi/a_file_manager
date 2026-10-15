import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// A folder that is still arriving when the user puts the list in another order: what arrives
/// later comes in the new order, sorted where it was read.
@MainActor
@Suite(.serialized)
internal struct PanelCovReadingTests {
    /// The program's folders and stand-ins.
    private let fixture: AppFixture

    /// A sandbox with the program's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.programFiles)
    }

    /// The order changed while the folder arrives: the list ends in the new order.
    @Test
    internal func theOrderChangedWhileAFolderArrivesIsTheOrderItEndsIn() async {
        let count = 1_200
        let slow = ScriptedFileSystem()
        // Names whose order by name and by extension differ.
        let names = (0..<count).map { index in String(format: "file%04d.", index) + ["c", "a", "b"][index % 3] }
        slow.batches = stride(from: 0, to: names.count, by: 100)
            .map { start in
                names[start..<min(start + 100, names.count)].map { slow.item(named: $0, in: "/slow") }
            }
        slow.holdBefore = 2
        slow.pauseBeforeSecondBatch = 0.25
        // The piece after the hold leaves on its own, before the last one.
        slow.pauseAfterHold = PanelLoading.secondPieceInterval * 2
        defer { slow.open() }
        let app = await fixture.startProgram()
        defer { app.stop() }
        app.kernel.fileSystems.register(slow)
        app.left.show(slow.url("/slow"))
        #expect(await AppWait.until { app.left.model.directory.path == "/slow" && !app.left.model.items.isEmpty })
        #expect(!app.left.model.isComplete)
        // The rest is let go, and the main thread waits until all of it has been read, so that
        // its pieces are on their way, in the order by name, when the list is sorted by extension.
        slow.open()
        #expect(Wait.until { slow.listingsEnded == 1 })
        #expect(app.commands.perform(.sortByExtension))
        await app.settle()
        #expect(app.left.model.isComplete && app.left.model.items.count == count)
        let extensions = app.names(app.left).map { $0.split(separator: ".").last.map(String.init) ?? "" }
        #expect(extensions == extensions.sorted())
        #expect(app.left.model.sort == app.left.model.wantedSort)
    }
}
