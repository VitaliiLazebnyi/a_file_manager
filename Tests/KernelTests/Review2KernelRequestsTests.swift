@testable import AFMKernel
import Foundation
import TestSupport
import Testing

private let folder = URL(fileURLWithPath: "/review2/requests")

private func file(_ name: String, size: Int64 = 1, in directory: URL = folder) -> FileItem {
    FileItem(url: directory.appendingPathComponent(name), name: name, isDirectory: false, size: size)
}

private func panel(_ items: [FileItem]) -> PanelModel {
    let model = PanelModel(directory: folder)
    model.show(Listing(directory: folder, items: items, parent: folder.deletingLastPathComponent(), root: URL(fileURLWithPath: "/")))
    return model
}

private final class QuittingPlugin: Plugin {
    let name: String
    var mayQuit = true
    var asked = 0, stopped = 0
    /// Finishes its work on another thread, a moment later, and answers twice.
    var finishesLate = false
    var sawFlag: CancellationFlag?

    init(_ name: String) { self.name = name }
    func start(in kernel: Kernel) {}
    func stop() { stopped += 1 }
    func shouldTerminate() -> Bool { asked += 1; return mayQuit }
    func prepareToQuit(cancellation: CancellationFlag, completion: @escaping () -> Void) {
        sawFlag = cancellation
        guard finishesLate else { return completion() }
        Thread.detachNewThread {
            usleep(20_000)
            completion()
            completion()
        }
    }
}

private final class PlainPlugin: Plugin {
    let name = "plain"
    func start(in kernel: Kernel) {}
}

/// What other areas asked the kernel for in review 2 (documentation/review-2/cross-requests).
@MainActor @Suite struct Review2KernelRequests {
    @Test func aPluginCanCallTheQuitOffAndFinishItsWorkBeforeIt() async {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), ui: ScriptedInteraction())
        let (first, second) = (QuittingPlugin("first"), QuittingPlugin("second"))
        kernel.load([first, PlainPlugin(), second])
        #expect(kernel.shouldTerminate() && first.asked == 1 && second.asked == 1)
        first.mayQuit = false
        #expect(!kernel.shouldTerminate() && second.asked == 1)
        second.finishesLate = true
        let flag = CancellationFlag()
        var isOnMain = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            kernel.prepareToQuit(cancellation: flag) {
                isOnMain = Thread.isMainThread
                continuation.resume()
            }
        }
        #expect(isOnMain && first.sawFlag === flag && second.sawFlag === flag && first.stopped == 0)
    }

    @Test func aQuestionFromAnotherThreadIsAskedOnTheMainThread() async {
        let ui = ScriptedInteraction()
        ui.choiceAnswers = [1]
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), ui: ui)
        let answer: (Int, Bool) = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var onMain = false
                let chosen = kernel.askUser { ui -> Int in
                    onMain = Thread.isMainThread
                    return ui.choose("Go on?", detail: "", buttons: ["Yes", "No"], style: .warning, defaultButton: nil)
                }
                continuation.resume(returning: (chosen, onMain))
            }
        }
        #expect(answer.0 == 1 && answer.1)
        #expect(kernel.askUser { _ in 7 } == 7)
    }

    @Test func anAnswerToABlockingQuestionCanBeDeliveredToTheMainThread() async {
        final class Owner {}
        let owner = Owner()
        var onMain = false
        let value: Int? = await withCheckedContinuation { continuation in
            BlockingCalls.answer(from: owner, to: "quick", { _ in 5 }, then: { (answer: Int?) in
                onMain = Thread.isMainThread
                continuation.resume(returning: answer)
            })
        }
        #expect(value == 5 && onMain)
        // Given up before the answer: nil is delivered, once, and the answer that comes later is dropped.
        let (flag, release) = (CancellationFlag(), DispatchSemaphore(value: 0))
        var delivered = 0
        let none: Int? = await withCheckedContinuation { continuation in
            BlockingCalls.answer(from: owner, to: "slow", cancellation: flag, { _ -> Int in
                release.wait()
                return 1
            }, then: { (answer: Int?) in
                delivered += 1
                continuation.resume(returning: answer)
            })
            flag.cancel()
        }
        release.signal()
        #expect(none == nil)
        // The main queue comes round once more: nothing else was delivered.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            BlockingCalls.answer(from: owner, to: "after", { _ in 0 }, then: { (_: Int?) in continuation.resume() })
        }
        #expect(delivered == 1)
    }

    @Test func theMarksCanLeaveTheMainThread() {
        let items = (0..<40_000).map { file("f\($0).txt", size: Int64($0 % 9)) }
        let model = panel(items)
        model.setFilter(PanelFilter(title: "even") { $0.size % 2 == 0 })
        let version = model.shownVersion
        let wanted = stride(from: 0, to: model.items.count, by: 3).map { $0 }
        #expect(model.setSelection(indices: wanted + [-1, model.items.count + 5], shownVersion: version))
        #expect(model.selectionCount == wanted.count)
        #expect(model.setSelected(false, indices: [0, 3], shownVersion: version) && model.selectionCount == wanted.count - 2)
        model.moveCursor(to: 5)
        let snapshot = model.operandsSnapshot()
        let done = DispatchSemaphore(value: 0)
        var (names, indices, marked): ([String], [Int], Bool) = ([], [], false)
        Thread.detachNewThread {
            names = snapshot.items().map(\.name)
            indices = snapshot.markedIndices()
            marked = snapshot.isMarked(at: 6) && !snapshot.isMarked(at: 0) && !snapshot.isMarked(at: 7) && !snapshot.isMarked(at: -1)
            done.signal()
        }
        done.wait()
        #expect(names == model.operands().map(\.name) && indices == Array(wanted.dropFirst(2)) && marked)
        #expect(snapshot.markedCount == wanted.count - 2 && snapshot.cursorItem?.name == model.cursorItem?.name && snapshot.shownVersion == version)
        // A filter moves what is shown, not the list: indexes worked out before are refused.
        let listVersion = model.listVersion
        model.setFilter(nil)
        #expect(model.listVersion == listVersion && model.shownVersion != version)
        #expect(!model.setSelection(indices: [1, 2], shownVersion: version) && !model.setSelected(true, indices: [1], shownVersion: version))
        model.clearSelection()
        #expect(model.operandsSnapshot().items().map(\.name) == [model.cursorItem!.name])
    }

    @Test func aFilteredListOfTwinsHandedInIsShownAsItIs() {
        // Two entries of one name, of which the filter lets the second through: the list
        // handed in must not be taken for the first (found by the fuzzer).
        let (a, b) = (URL(fileURLWithPath: "/review2/a"), URL(fileURLWithPath: "/review2/b"))
        let items = [file("twin", size: 0, in: a), file("twin", size: 5, in: b), file("other", size: 3), file("twin", size: 5, in: a)]
        let model = panel(items)
        let filter = PanelFilter(title: "big") { $0.size > 1 }
        #expect(model.setFilter(filter, prefiltered: PanelModel.filtered(model.listedItems, by: filter), listVersion: model.listVersion))
        #expect(model.items.map(\.size) == model.listedItems.filter(filter.matches).map(\.size) && model.items.count == 3)
        model.selectAll()
        #expect(model.selectionCount == 3 && model.totals.selectedBytes == 13 && model.operands().allSatisfy { $0.size > 1 })
        // Asked again and again (the model makes its index of names on the way): the same answer.
        for _ in 0..<4 {
            for item in model.items { #expect(model.isSelected(item)) }
            let hidden = model.isSelected(items[0])
            #expect(!hidden)
        }
        model.setFilter(nil)
        #expect(model.selectionCount == 3 && !model.isSelected(row: model.items.firstIndex { $0.size == 0 }! + 1))
    }

    @Test func whatAFileSystemNeedNotOfferHasADefault() throws {
        let memory = MemoryFileSystem(scheme: "mem")
        _ = memory.addFile("/a/x.txt")
        let live = CancellationFlag(), cancelled = CancellationFlag()
        cancelled.cancel()
        try memory.createDirectory(at: memory.url("/a/new"), cancellation: live)
        try memory.move(memory.url("/a/x.txt"), to: memory.url("/a/y.txt"), replacing: false, cancellation: live)
        #expect(memory.exists("/a/new") && memory.exists("/a/y.txt"))
        #expect(throws: (any Error).self) { try memory.remove(memory.url("/a/y.txt"), cancellation: cancelled) }
        #expect(throws: (any Error).self) { try memory.createDirectory(at: memory.url("/a/never"), cancellation: cancelled) }
        #expect(memory.exists("/a/y.txt") && !memory.exists("/a/never"))
        try memory.remove(memory.url("/a/y.txt"), cancellation: live)
        #expect(!memory.exists("/a/y.txt"))
        // A folder that must be new.
        try memory.createDirectory(at: memory.url("/a/fresh"), exclusive: true)
        #expect(throws: (any Error).self) { try memory.createDirectory(at: memory.url("/a/fresh"), exclusive: true) }
        try memory.createDirectory(at: memory.url("/a/fresh"), exclusive: false)
        #expect(memory.volume(of: memory.url("/a"), cancellation: cancelled) == nil)
        #expect(memory.realLocation(of: memory.url("/a")) == nil && !memory.connectsToServer)
        #expect(memory.readOrder(of: [memory.url("/b"), memory.url("/a")]) == [memory.url("/b"), memory.url("/a")])
        // Whoever keeps changes to a file back is asked to write them before the file is used.
        let registry = FileSystemRegistry()
        registry.register(memory)
        var flushed: [String] = []
        registry.addFlusher { url, _ in flushed.append(url.lastPathComponent) }
        registry.addFlusher { url, flag in if url.lastPathComponent == "bad" || flag.isCancelled { throw FileSystemError.notSupported("Flushing") } }
        try registry.flushPendingWrites(to: memory.url("/a/archive.zip"), cancellation: live)
        #expect(flushed == ["archive.zip"])
        #expect(throws: (any Error).self) { try registry.flushPendingWrites(to: memory.url("/a/bad"), cancellation: live) }
        #expect(registry.realLocation(of: memory.url("/a")) == memory.url("/a"))
    }

    @Test func anEntryCanSayWhatItsLinkPointsToAndWhereItLives() throws {
        var item = file("link")
        #expect(item.linkTargetSize == nil && item.device == nil)
        item.linkTargetSize = 0
        item.device = 16_777_233
        #expect(item.linkTargetSize == 0 && item.device == 16_777_233 && item != file("link"))
        let made = FileItem(url: folder, name: "x", isDirectory: false, linkTargetSize: 77, device: -3)
        #expect(made.linkTargetSize == 77 && made.device == -3 && made.isSameEntry(as: FileItem(url: folder, name: "x", isDirectory: false)))
        // The same file under two names.
        let sandbox = try Sandbox()
        let original = try sandbox.file("a/original.txt"), other = try sandbox.file("a/other.txt")
        try FileManager.default.linkItem(at: original, to: sandbox.url("a/hard.txt"))
        try FileManager.default.createSymbolicLink(at: sandbox.url("a/soft.txt"), withDestinationURL: original)
        #expect(original.isSameFile(as: sandbox.url("a/hard.txt")) && original.isSameFile(as: sandbox.url("a/../a/original.txt")))
        #expect(!original.isSameFile(as: other) && !original.isSameFile(as: sandbox.url("a/none.txt")))
        #expect(!original.isSameFile(as: sandbox.url("a/soft.txt")) && original.isSameFile(as: sandbox.url("a/soft.txt"), followingLinks: true))
        #expect(URL(string: "ftp://h/a")!.isSameFile(as: URL(string: "ftp://h/a/")!))
    }

    @Test func settingsKeysSayWhatTheyAre() {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), ui: ScriptedInteraction())
        let keys = kernel.settingsKeys
        keys.declare("commands.user", kind: .runsCode)
        keys.declare(prefix: "findFiles.history.", kind: .history)
        keys.declare(prefix: "findFiles.", kind: .ordinary) { $0.count < 4 }
        #expect(keys.kind(of: "commands.user") == .runsCode && keys.kind(of: "findFiles.history.text") == .history)
        #expect(keys.kind(of: "findFiles.size") == .ordinary && keys.kind(of: "unknown") == nil && keys.kind(of: "commands.user2") == nil)
        #expect(keys.accepts(Data([1, 2]), forKey: "findFiles.size") && !keys.accepts(Data([1, 2, 3, 4, 5]), forKey: "findFiles.size"))
        #expect(!keys.accepts(Data(), forKey: "unknown") && keys.all.count == 3)
        // Large values go where the store keeps them; by default, with the rest.
        let settings = MemorySettings()
        settings.scoped(to: "rename").setLarge(Data([9]), forKey: "undo")
        #expect(settings.largeData(forKey: "rename.undo") == Data([9]) && settings.scoped(to: "rename").largeData(forKey: "undo") == Data([9]))
    }

    @Test func aBrokenPipeIsAnErrorHereAndStillEndsTheProgramsWeStart() {
        _ = Kernel(productName: "Test", settings: MemorySettings(), ui: ScriptedInteraction())
        // Writing to a pipe nobody reads fails; it does not end the program.
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        close(ends[0])
        let written = write(ends[1], "x", 1)
        let failure = errno
        close(ends[1])
        #expect(written == -1 && failure == EPIPE)
        // A program started from here has the signal as the system gives it: it ends when
        // its reader is gone (a handler is not passed on; "ignore" would be).
        var pid: pid_t = 0
        let words: [String] = ["/bin/sh", "-c", "kill -PIPE $$; exit 0"]
        var arguments: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) }
        arguments.append(nil)
        defer { arguments.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sh", nil, nil, &arguments, environ) == 0)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        // Ended by a signal, and that signal.
        #expect(status & 0x7F == SIGPIPE)
    }

    @Test func severalChangesOfTheTabsAreAnnouncedOnce() {
        let tabs = PanelTabs(PanelModel(directory: folder))
        var announced = 0
        tabs.onChange = { announced += 1 }
        tabs.performBatch {
            tabs.openTab(showing: folder.appendingPathComponent("a"))
            tabs.performBatch { tabs.openTab(showing: folder.appendingPathComponent("b"), activate: false) }
            tabs.activate(0)
        }
        #expect(announced == 1 && tabs.count == 3)
        tabs.performBatch {}
        #expect(announced == 1)
        tabs.activate(1)
        #expect(announced == 2)
    }

    @Test func aColumnCanBeToldThatItsAnswerIsNoLongerWanted() {
        let plain = ContentColumn(id: "plain", title: "Plain") { $0.name.uppercased() }
        let patient = ContentColumn(id: "patient", title: "Patient", cancellableValue: { item, flag in flag.isCancelled ? "given up" : item.name })
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(plain.value(file("a")) == "A" && plain.cancellableValue(file("a"), CancellationFlag()) == "A" && plain.cancellableValue(file("a"), cancelled) == "")
        #expect(patient.value(file("a")) == "a" && patient.cancellableValue(file("a"), cancelled) == "given up")
    }
}
