import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Large and slow folders in the whole program: shown while they arrive, left without waiting.
@MainActor
@Suite(.serialized)
internal struct AppSlowFolderTests {
    /// The program's folders and stand-ins.
    private let fixture: AppFixture

    /// A sandbox with the program's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.programFiles)
    }

    /// What has arrived of a slow folder is shown and can be used; the rest follows in order.
    @Test
    internal func aSlowDirectoryIsShownWhileItIsStillArriving() async throws {
        let count = 3_000
        // The listing is held after its second batch until the test says go; no timing decides
        // whether it is still arriving when the checks are made.
        let slow = ScriptedFileSystem()
        let arriving = (0..<count).map { String(format: "file%04d.txt", ($0 * 7_919) % count) } + ["zz-folder"]
        slow.batches = stride(from: 0, to: arriving.count, by: 250)
            .map { start in
                arriving[start..<min(start + 250, arriving.count)]
                    .map { name in
                        slow.item(named: name, in: "/slow", isDirectory: name == "zz-folder")
                    }
            }
        slow.holdBefore = 2
        slow.pauseBeforeSecondBatch = 0.25
        defer { slow.open() }
        let app = await fixture.startProgram()
        defer { app.stop() }
        app.kernel.fileSystems.register(slow)
        app.left.show(slow.url("/slow"))

        // After a moment the panel shows what has arrived, and says that more is coming.
        #expect(await AppWait.until { app.left.model.directory.path == "/slow" && !app.left.model.items.isEmpty })
        #expect(!app.left.model.isComplete && app.left.isLoading && app.left.model.items.count < count)
        #expect(app.left.tableView.numberOfRows == app.left.model.rowCount)
        // What is there can be used: the cursor moves, an item is marked; "all" has to wait.
        #expect(try app.press(124, []))
        let underCursor = try #require(app.left.model.cursorItem).name
        #expect(try app.press(49, []) && app.left.model.selection == [underCursor])
        #expect(!app.commands.isEnabled(.selectAll) && app.commands.isEnabled(.copy))

        // The rest arrives without disturbing the cursor or the selection.
        let partial = app.left.model.items.count
        slow.open()
        #expect(await AppWait.until { app.left.model.items.count > partial })
        #expect(app.left.model.cursorItem?.name == underCursor && app.left.model.selection == [underCursor])
        await app.settle()
        #expect(app.left.model.isComplete && app.left.model.items.count == count + 1 && !app.left.isLoading)
        #expect(app.left.model.cursorItem?.name == underCursor && app.left.model.selection == [underCursor])
        // Everything is in order, the folder first.
        let names = app.names(app.left)
        #expect(
            names.first == "zz-folder"
                && Array(names.dropFirst()) == (0..<count).map { String(format: "file%04d.txt", $0) }
        )
        #expect(app.commands.isEnabled(.selectAll))
    }

    /// A folder whose server has not answered yet is entered at once, with its path and a wheel.
    @Test
    internal func aFolderOnASlowServerIsEnteredAtOnce() async {
        // The server says nothing until the test lets it.
        let late = ScriptedFileSystem()
        late.batches = [(0..<10).map { late.item(named: "file\($0).txt", in: "/late") }]
        late.holdBefore = 0
        defer { late.open() }
        let app = await fixture.startProgram()
        defer { app.stop() }
        app.kernel.fileSystems.register(late)
        app.commands.perform(.changeDirectory, .location(late.url("/late")))
        // The server has not said anything yet, but the panel is in the folder: its path is
        // shown, the list is empty apart from [..], and a wheel turns in the status line.
        let entered = await AppWait.until { app.left.model.directory.path == "/late" }
        #expect(entered && app.left.model.isOpening && app.left.model.items.isEmpty)
        #expect(app.left.tableView.numberOfRows == 1 && app.left.showsActivity)
        #expect(app.left.statusLineText == "Reading \(app.kernel.fileSystems.displayPath(late.url("/late")))…")
        // Commands that need the entries wait; the way back is open.
        #expect(
            !app.commands.isEnabled(.copy) && !app.commands.isEnabled(.selectAll) && app.commands.isEnabled(.goToParent)
        )
        #expect(app.left.model.backLocation?.lastPathComponent == "A")

        late.open()
        await app.settle()
        #expect(app.names(app.left).count == 10 && app.left.model.isComplete && !app.left.showsActivity)
        #expect(app.left.statusLineText == "0 k / 0 k in 0 / 10 file(s)")
        #expect(app.left.model.backLocation?.lastPathComponent == "A" && app.left.model.forwardLocation == nil)
    }

    /// Going up from a folder that is still being opened does not wait for it; its answer changes nothing.
    @Test
    internal func leavingAFolderThatIsStillBeingOpened() async {
        let late = ScriptedFileSystem()
        late.batches = [[late.item(named: "file.txt", in: "/late")]]
        late.batchesAt["/"] = [[late.item(named: "late", in: "", isDirectory: true)]]
        late.holdBefore = 0
        defer { late.open() }
        let app = await fixture.startProgram()
        defer { app.stop() }
        app.kernel.fileSystems.register(late)
        app.left.show(late.url("/late"))
        #expect(await AppWait.until { app.left.model.isOpening })
        // Backspace: up again, without waiting for the answer about this folder.
        app.commands.perform(.goToParent)
        await app.settle()
        #expect(
            app.left.model.directory.path == "/" && app.left.model.cursorItem?.name == "late" && !app.left.showsActivity
        )
        // The abandoned reading is ended, and the answer it might have given changes nothing.
        #expect(await AppWait.until { late.listingsBegun == 2 && late.listingsEnded == 2 })
        late.open()
        #expect(app.left.model.directory.path == "/" && app.left.model.isComplete)
    }

    /// A slow folder that cannot be read in the end is left for the folder the panel came from.
    @Test
    internal func aSlowFolderThatCannotBeReadIsLeftAgain() async {
        // The server does not answer until the test lets it, and then says no.
        let locked = ScriptedFileSystem()
        locked.holdBefore = 0
        locked.failure = CocoaError(.fileReadNoPermission)
        defer { locked.open() }
        let app = await fixture.startProgram()
        defer { app.stop() }
        app.kernel.fileSystems.register(locked)
        app.cursor(app.left, on: "one.txt")
        app.left.show(locked.url("/locked"))
        #expect(await AppWait.until { app.left.model.directory.path == "/locked" && app.left.model.isOpening })
        locked.open()
        // The message comes from the run loop after the panel went back, whenever the machine gets
        // to it: waited for, not given a time.
        #expect(
            await AppWait.until {
                !fixture.user.log.isEmpty && app.left.model.directory.lastPathComponent == "A"
                    && app.left.model.isComplete
            }
        )
        await app.settle()
        // Back in the folder it came from, with the cursor where it was, and the user is told.
        #expect(
            app.left.model.directory.lastPathComponent == "A" && app.names(app.left) == ["docs", "one.txt", "two.txt"]
        )
        #expect(app.left.model.cursorItem?.name == "one.txt" && app.left.model.isComplete && !app.left.showsActivity)
        #expect(app.left.model.forwardLocation == nil && fixture.user.log == ["inform: The folder cannot be read!"])
        #expect(app.left.tableView.numberOfRows == 4)
    }

    /// A folder that is read at once never shows an empty list on the way.
    @Test
    internal func anOrdinaryFolderAppearsWholeWithoutAnEmptyMoment() async {
        let app = await fixture.startProgram()
        defer { app.stop() }
        var sawEmpty = false
        app.left.model.onChange = { [weak panel = app.left] _ in
            if panel?.model.isOpening == true {
                sawEmpty = true
            }
        }
        app.cursor(app.left, on: "docs")
        app.commands.perform(.open)
        await app.settle()
        #expect(app.left.model.directory.lastPathComponent == "docs" && !sawEmpty)
    }

    /// Going elsewhere while a folder is arriving stops its listing: nothing of it shows up later.
    @Test
    internal func goingElsewhereStopsASlowListing() async {
        let memory = fixture.memory
        for index in 0..<2_000 {
            memory.addFile("/slow/file\(index).txt")
        }
        memory.addFile("/quick/only.txt")
        memory.listBatchSize = 100
        // Slow enough that the folder is "arriving" for most of a minute: the test has to see
        // it in that state, and under the thread sanitizer a listing of 2 s was over, or had
        // not begun, whenever the test got to look within the 10 s it used to wait.
        memory.listBatchDelay = 2
        let app = await fixture.startProgram()
        defer { app.stop() }
        app.left.show(memory.url("/slow"))
        #expect(await AppWait.until { app.left.model.directory.path == "/slow" && !app.left.model.isComplete })
        app.left.show(memory.url("/quick"))
        await AppWait.until { app.left.model.directory.path == "/quick" && app.left.model.isComplete }
        await app.settle()
        #expect(
            app.left.model.directory.path == "/quick" && app.names(app.left) == ["only.txt"]
                && app.left.model.isComplete
        )
        // Nothing of the abandoned listing arrives later (its next piece would have been due within 2 s).
        await AppWait.until(seconds: 3) { false }
        #expect(app.names(app.left) == ["only.txt"])
    }
}
