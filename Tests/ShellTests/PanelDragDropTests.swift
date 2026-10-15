import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Drag and drop through the real program (spec 05 › Drag & drop): what a drag carries, where
/// a drop goes, and how it is carried out.
@MainActor
@Suite(.serialized)
internal struct PanelDragDropTests {
    private let program: PanelProgram

    /// The program's folders, with `B/fresh.txt` and a file in the memory file system.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
        program.memory.addFile("/M/remote.txt", "far")
    }

    /// Starts the program with the plugins a file manager cannot do without.
    private func start() async -> PanelProgram.Running {
        await program.start(plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard), fileSystems: [])
    }

    /// A drag carries the marked items or the row's item; a drop goes into a folder row, up
    /// through `[..]`, or into the panel's folder, and is refused where it changes nothing or
    /// where nothing can be written.
    @Test
    internal func whatADragCarriesAndWhereADropGoes() async {
        let app = await start()
        defer {
            app.stop()
            PanelDrop.endDrag()
        }
        let all: NSDragOperation = [.copy, .move, .generic]
        // Rows of the left panel: [..], docs, one.txt, two.txt.
        #expect(app.left.draggedItems(fromRow: 0).isEmpty && app.left.draggedItems(fromRow: 2).map(\.name) == ["one.txt"])
        app.left.model.setSelected(true, rows: 2...3)
        #expect(app.left.draggedItems(fromRow: 3).map(\.name) == ["one.txt", "two.txt"])
        #expect(app.left.draggedItems(fromRow: 1).map(\.name) == ["docs"] && app.left.draggingItems(forRow: 3).count == 2)
        let fresh = program.box.url("B/fresh.txt")
        // Onto a folder row: into that folder. Onto a file or empty space: into the panel's folder.
        let onFolder = app.left.dropPlan(for: [fresh], row: 1, modifiers: [], allowed: all)
        #expect(onFolder?.destination.path == program.box.url("A/docs").path && onFolder?.row == 1 && onFolder?.kind == .move)
        let onFile = app.left.dropPlan(for: [fresh], row: 2, modifiers: .option, allowed: all)
        #expect(onFile?.destination.path == program.box.url("A").path && onFile?.row == -1 && onFile?.kind == .copy)
        #expect(app.left.dropPlan(for: [fresh], row: -1, modifiers: [], allowed: all)?.row == -1)
        // Onto [..]: into the folder above.
        #expect(app.left.dropPlan(for: [fresh], row: 0, modifiers: [], allowed: all)?.destination.path == program.box.root.path)
        // A panel's own items dropped on its background change nothing, unless copied.
        let own = [program.box.url("A/one.txt")]
        #expect(app.left.dropPlan(for: own, row: -1, modifiers: [], allowed: all) == nil)
        #expect(app.left.dropPlan(for: own, row: -1, modifiers: .option, allowed: all)?.kind == .copy)
        #expect(app.left.dropPlan(for: own, row: 1, modifiers: [], allowed: all)?.kind == .move)
        #expect(app.left.dropPlan(for: [program.box.url("A/docs")], row: 1, modifiers: [], allowed: all) == nil)
        #expect(app.left.dropPlan(for: [], row: 1, modifiers: [], allowed: all) == nil)
        #expect(app.left.dropPlan(for: [fresh], row: 1, modifiers: .command, allowed: .copy) == nil)
        // Between file systems it is a copy; a file system that cannot be written takes nothing.
        #expect(app.left.dropPlan(for: [program.memory.url("/M/remote.txt")], row: -1, modifiers: [], allowed: all)?.kind == .copy)
        app.right.show(program.memory.url("/M"))
        await program.settle(app)
        #expect(app.right.dropPlan(for: own, row: -1, modifiers: [], allowed: all)?.kind == .copy)
        program.memory.capabilities = []
        #expect(app.right.dropPlan(for: own, row: -1, modifiers: [], allowed: all) == nil)
    }

    /// A drop is carried out by the file-transfer service, after the question when the user
    /// wants one; nothing is taken while a job runs; a copy next to the original gets a new name.
    @Test
    internal func aDropIsCarriedOutByTheFileTransferService() async throws {
        let app = await start()
        defer { app.stop() }
        let all: NSDragOperation = [.copy, .move, .generic]
        let move = try #require(app.left.dropPlan(for: [program.box.url("B/fresh.txt")], row: 1, modifiers: [], allowed: all))
        program.interaction.choiceAnswers = [1]
        app.left.carryOut(move)
        await program.settle(app)
        #expect(program.interaction.log == ["choose: Move 1 item to / \(program.box.url("A/docs").path)"])
        #expect(program.box.exists("B/fresh.txt"))
        program.interaction.choiceAnswers = [0]
        app.left.carryOut(move)
        #expect(app.kernel.jobs.isBusy)
        // While the job runs, nothing else is taken.
        #expect(app.left.dropPlan(for: [program.box.url("B/fresh.txt")], row: 1, modifiers: [], allowed: all) == nil)
        #expect(app.left.draggedItems(fromRow: 2).isEmpty)
        app.left.carryOut(move)
        await program.settle(app)
        #expect(program.box.read("A/docs/fresh.txt") == "fresh" && !program.box.exists("B/fresh.txt") && app.names(app.right).isEmpty)
        // Without the question; from another file system; and a copy next to the original.
        program.settings.set(false, forKey: PanelSettings.confirmsDropsKey)
        app.shell.panelCoordinator.applySettings()
        let copy = try #require(app.left.dropPlan(for: [program.memory.url("/M/remote.txt")], row: -1, modifiers: [], allowed: all))
        app.left.carryOut(copy)
        await program.settle(app)
        #expect(program.box.read("A/remote.txt") == "far" && program.memory.exists("/M/remote.txt"))
        #expect(app.names(app.left).contains("remote.txt"))
        let duplicate = try #require(app.left.dropPlan(for: [program.box.url("A/one.txt")], row: -1, modifiers: .option, allowed: all))
        app.left.carryOut(duplicate)
        await program.settle(app)
        #expect(program.box.read("A/one (2).txt") == "new" && program.box.exists("A/one.txt") && program.interaction.log.count == 2)
    }

    /// The program's own drag carries its ticket, and the items stay inside the program; other
    /// programs get the files of the local disks, never those of another file system.
    @Test
    internal func aPanelsDragTypeIsOnlyBelievedFromThisProgramsOwnDrag() async {
        let app = await start()
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            PanelDrop.endDrag()
            pasteboard.releaseGlobally()
            app.stop()
        }
        app.left.model.setSelected(true, rows: 2...3)
        let written = app.left.draggingItems(forRow: 3)
        pasteboard.clearContents()
        pasteboard.writeObjects(written)
        #expect(written.count == 2 && PanelDrop.locations(on: pasteboard).map(\.lastPathComponent) == ["one.txt", "two.txt"])
        PanelDrop.endDrag()
        #expect(PanelDrop.locations(on: pasteboard).map(\.lastPathComponent) == ["one.txt", "two.txt"])
        // Items of another file system are in the drag, but not for other programs.
        app.right.show(program.memory.url("/M"))
        await program.settle(app)
        let remote = app.right.draggingItems(forRow: 1)
        pasteboard.clearContents()
        pasteboard.writeObjects(remote)
        #expect(PanelDrop.locations(on: pasteboard).map(\.absoluteString) == ["mem:///M/remote.txt"])
        PanelDrop.endDrag()
        #expect(PanelDrop.locations(on: pasteboard).isEmpty)
    }
}
