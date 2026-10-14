import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// The Multi-Rename Tool driven through its command and its session, on a file system in
/// memory and on the local disk. No window is involved.
@MainActor @Suite struct MultiRenameRuns {
    let memory = MemoryFileSystem()
    let box: Sandbox
    let settings = MemorySettings()
    let plugin: MultiRenamePlugin
    let bench: TestBench

    var ui: ScriptedInteraction { bench.ui }
    var left: FakePanel { bench.left }

    init() throws {
        box = try Sandbox()
        for (index, name) in ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg"].enumerated() {
            memory.addFile(
                "/photos/" + name, "p\(index)",
                modified: Date(timeIntervalSince1970: 1_764_583_509 + Double(index) * 86_400))
        }
        memory.addFile("/photos/notes.txt", "n")
        memory.addDirectory("/other")
        plugin = MultiRenamePlugin(opensWindows: false, logDirectory: box.url("log"))
        bench = TestBench(
            plugins: [plugin], fileSystems: [LocalFileSystem(), memory], left: memory.url("/photos"),
            right: memory.url("/other"),
            settings: settings)
    }

    /// Opens the tool on the given names of the left panel (all of them when none are given).
    @discardableResult
    func open(_ names: [String] = [], settingsName: String? = nil) -> MultiRenameSession {
        left.model.clearSelection()
        for name in names { left.model.select(mask: name) }
        if names.isEmpty { left.model.selectAll() }
        #expect(bench.commands.perform(.multiRename, settingsName.map(CommandArgument.text) ?? .none))
        guard let session = plugin.session else { preconditionFailure("the command opens a session") }
        return session
    }

    func names(_ session: MultiRenameSession) -> [String?] { session.rows.map(\.newName) }
    var photos: [String] { memory.allPaths.filter { $0.hasPrefix("/photos/") }.map { String($0.dropFirst(8)) } }

    // MARK: Registration

    @Test func commandMenuAndPreferences() {
        #expect(bench.commands[.multiRename]?.title == "Multi-Rename Tool…")
        #expect(bench.kernel.keyBindings.command(for: Shortcut(.character("m"), .control)) == .multiRename)
        #expect(bench.kernel.menus.menus.first?.items == [.multiRename])
        #expect(bench.kernel.menus.contextMenu(onItem: true) == [.multiRename])
        #expect(bench.kernel.toolbar.defaultLayout.compactMap { $0?.command } == [.multiRename])
        #expect(bench.kernel.preferences.pages.map(\.title) == ["Multi-Rename Tool"])
        memory.capabilities = []
        #expect(!bench.commands.isEnabled(.multiRename))
    }

    @Test func operandsAreTheSelectionOrTheCursorItem() {
        #expect(open(["IMG_1002.jpg", "notes.txt"]).rows.map(\.entry.name) == ["IMG_1002.jpg", "notes.txt"])
        left.model.clearSelection()
        left.moveCursor(toName: "IMG_1003.jpg")
        bench.commands.perform(.multiRename)
        #expect(plugin.session?.rows.map(\.entry.name) == ["IMG_1003.jpg"])
    }

    // MARK: Preview

    @Test func previewFollowsTheSettings() {
        let session = open(["IMG_*"])
        #expect(
            names(session) == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg"]
                && session.rows.allSatisfy { $0.status == .unchanged })
        session.settings.nameMask = "Photo_[C]_[Y]-[M]-[D]"
        session.settings.counter = CounterDefinition(start: 110, step: 15, digits: 1)
        #expect(names(session) == ["Photo_110_2025-12-01.jpg", "Photo_125_2025-12-02.jpg", "Photo_140_2025-12-03.jpg"])
        #expect(session.rows.allSatisfy { $0.status == .ready } && session.counts.changing == 3)
        session.settings.nameMask = "[P]-[G][N5-]"
        #expect(names(session).first == "photos-1001.jpg")
        session.settings.nameMask = "[Q]"
        #expect(
            names(session) == [nil, nil, nil] && session.rows.allSatisfy { $0.status == .error }
                && session.problem != nil)
        #expect(photos == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"])
    }

    @Test func previewMarksConflictsAndInvalidNames() {
        let session = open(["IMG_*"])
        session.settings.nameMask = "same"
        #expect(session.rows.allSatisfy { $0.status == .duplicate } && session.counts.conflicts == 3)
        session.settings.nameMask = "[N1-7]"
        #expect(session.rows.map(\.status) == [.duplicate, .duplicate, .duplicate])
        session.settings = RenameSettings()
        session.settings.search = "IMG_1001.jpg|IMG_1002"
        session.settings.replacement = "notes.txt|IMG_1003"
        // The first collides with a file outside the list, the second with one that stays.
        #expect(session.rows.map(\.status) == [.exists, .duplicate, .unchanged])
        session.settings = RenameSettings()
        session.settings.nameMask = ""
        session.settings.extensionMask = ""
        #expect(session.rows.allSatisfy { $0.status.isInvalid } && session.counts.errors == 3)
    }

    @Test func previewInTheBackground() async {
        let items = (0..<3000).map {
            FileItem(url: memory.addFile("/many/f\($0).txt"), name: "f\($0).txt", isDirectory: false)
        }
        var settings = RenameSettings()
        settings.nameMask = "[N]_[C:4]"
        let session = MultiRenameSession(
            kernel: bench.kernel, items: items, store: RenameStore(settings: self.settings), settings: settings,
            logDirectory: box.url("log"))
        var changes = 0
        session.onChange = { changes += 1 }
        // Changes that overtake each other leave the result of the last one.
        session.settings.nameMask = "[N]-[C:5]"
        session.settings.nameMask = "[N]+[C:5]"
        // The result comes back over the main queue, which this test shares with every other
        // test of the process; in a full run that alone has taken more than 20 s. The limit
        // only ends a preview that never comes.
        let deadline = Date().addingTimeInterval(600)
        while session.isComputing && Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(!session.isComputing && changes >= 1)
        #expect(session.rows.first?.newName == "f0+00001.txt" && session.rows.last?.newName == "f2999+03000.txt")
        #expect(session.rows.allSatisfy { $0.status == .ready })
    }

    // MARK: Runs

    @Test func renamesAndEmptiesTheList() {
        let session = open(["IMG_*"])
        session.settings.nameMask = "Photo_[C:2]"
        session.settings.letterCase = .upper
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.renamed.count == 3 && result?.failures.isEmpty == true)
        #expect(photos == ["PHOTO_01.JPG", "PHOTO_02.JPG", "PHOTO_03.JPG", "notes.txt"])
        #expect(memory.contents("/photos/PHOTO_02.JPG") == "p1")
        // No message; the list is empty and the panel shows the new names.
        #expect(session.rows.isEmpty && !ui.log.contains { $0.hasPrefix("inform") })
        #expect(left.names.sorted() == ["PHOTO_01.JPG", "PHOTO_02.JPG", "PHOTO_03.JPG", "notes.txt"])
        #expect(session.canUndo && session.hasResultList)
        #expect(bench.jobService.titles == ["Multi-Rename:"])
        #expect(RenameStore(settings: settings).history(.nameMask) == ["Photo_[C:2]"])
    }

    @Test func unchangedItemsStayInTheList() {
        let session = open()
        session.settings.search = "IMG_"
        session.settings.replacement = "pic"
        session.start()
        #expect(photos == ["notes.txt", "pic1001.jpg", "pic1002.jpg", "pic1003.jpg"])
        #expect(session.rows.map(\.entry.name) == ["notes.txt"])
    }

    @Test func resultLog() throws {
        let session = open(["IMG_1001.jpg", "IMG_1002.jpg"])
        session.settings.nameMask = "[C]/pic"
        session.start()
        let log = try String(contentsOf: box.url("log/renlog.txt"), encoding: .utf8)
        #expect(log == "\"mem:/photos/IMG_1001.jpg\" -> \"1/pic.jpg\"\n\"mem:/photos/IMG_1002.jpg\" -> \"2/pic.jpg\"\n")
        #expect(session.logURL == box.url("log/renlog.txt"))
        // Without a viewer the log is shown in a form.
        ui.formAnswers = [.accept]
        session.showResultList()
        #expect(ui.log.last == "form: Result list")
    }

    @Test func slashesMoveIntoFoldersThatAreCreated() {
        let session = open(["IMG_*"])
        session.settings.nameMask = "[C+1/2]/[N]"
        session.start()
        #expect(
            memory.allPaths.filter { $0.hasPrefix("/photos/") && $0.hasSuffix(".jpg") }
                == ["/photos/1/IMG_1001.jpg", "/photos/1/IMG_1002.jpg", "/photos/2/IMG_1003.jpg"])
        ui.choiceAnswers = [0]
        session.undo()
        // Undo puts the files back and leaves the folders.
        #expect(photos == ["1", "2", "IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"])
    }

    @Test func swapsAndShiftsThroughGivenNames() {
        let session = open(["IMG_*"])
        session.loadNames(fromText: "IMG_1002.jpg\r\nIMG_1003.jpg\r\nIMG_1001.jpg\r\n")
        #expect(session.givenNames?.count == 3 && session.rows.allSatisfy { $0.status == .ready })
        session.start()
        #expect(photos == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"])
        #expect(
            ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg"].map { memory.contents("/photos/" + $0) } == [
                "p2", "p0", "p1"
            ])
        #expect(!memory.allPaths.contains { $0.contains("afm-rename") })
        ui.choiceAnswers = [0]
        session.undo()
        #expect(
            ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg"].map { memory.contents("/photos/" + $0) } == [
                "p0", "p1", "p2"
            ])
        #expect(!memory.allPaths.contains { $0.contains("afm-rename") })
    }

    @Test func counterShiftOnTheLocalDisk() throws {
        for index in 1...4 { try box.file("A/\(index).txt", "content \(index)") }
        left.show(box.url("A"))
        let session = open()
        session.settings.nameMask = "[C2]"
        #expect(
            names(session) == ["2.txt", "3.txt", "4.txt", "5.txt"] && session.rows.allSatisfy { $0.status == .ready })
        session.start()
        #expect(namesOnDisk(box.url("A")) == ["2.txt", "3.txt", "4.txt", "5.txt"])
        #expect((2...5).map { box.read("A/\($0).txt") } == ["content 1", "content 2", "content 3", "content 4"])
        ui.choiceAnswers = [0]
        session.undo()
        #expect(namesOnDisk(box.url("A")) == ["1.txt", "2.txt", "3.txt", "4.txt"])
        #expect(box.read("A/1.txt") == "content 1" && box.read("A/4.txt") == "content 4")
    }

    @Test func swapAndCaseOnlyRenameOnTheLocalDisk() throws {
        try box.file("A/one.txt", "1")
        try box.file("A/two.txt", "2")
        try box.file("A/readme.md", "r")
        left.show(box.url("A"))
        let session = open()
        #expect(session.rows.map(\.entry.name) == ["one.txt", "readme.md", "two.txt"])
        session.loadNames(fromText: "two.txt\nREADME.md\none.txt")
        #expect(session.rows.allSatisfy { $0.status == .ready })
        session.start()
        #expect(namesOnDisk(box.url("A")) == ["README.md", "one.txt", "two.txt"])
        #expect(box.read("A/one.txt") == "2" && box.read("A/two.txt") == "1" && box.read("A/README.md") == "r")
        ui.choiceAnswers = [0]
        session.undo()
        #expect(namesOnDisk(box.url("A")) == ["one.txt", "readme.md", "two.txt"])
        #expect(box.read("A/one.txt") == "1" && box.read("A/two.txt") == "2")
    }

    @Test func allUppercaseOnTheLocalDisk() throws {
        try box.file("A/a.txt", "a")
        try box.file("A/b.txt", "b")
        left.show(box.url("A"))
        let session = open()
        session.settings.letterCase = .upper
        #expect(session.rows.allSatisfy { $0.status == .ready })
        session.start()
        #expect(namesOnDisk(box.url("A")) == ["A.TXT", "B.TXT"] && box.read("A/A.TXT") == "a")
    }

    // MARK: Conflicts

    @Test func conflictsAreAutoRenamedWhenAsked() {
        let session = open(["IMG_*"])
        session.settings.nameMask = "notes"
        session.settings.extensionMask = "txt"
        ui.choiceAnswers = [0]
        session.start()
        #expect(photos == ["notes (2).txt", "notes (3).txt", "notes (4).txt", "notes.txt"])
        #expect(memory.contents("/photos/notes.txt") == "n" && memory.contents("/photos/notes (2).txt") == "p0")
        #expect(ui.log.contains { $0.hasPrefix("choose: Name conflict: 3 file(s)") })
    }

    @Test func conflictsCanBeSkippedOrCancelTheRun() {
        let session = open()
        session.settings.search = "IMG_1001.jpg|IMG_1002"
        session.settings.replacement = "notes.txt|pic"
        // Cancel: nothing happens.
        session.start()
        #expect(photos == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"] && !session.canUndo)
        ui.choiceAnswers = [1]
        session.start()
        #expect(photos == ["IMG_1001.jpg", "IMG_1003.jpg", "notes.txt", "pic.jpg"])
        #expect(session.rows.map(\.entry.name) == ["IMG_1001.jpg", "IMG_1003.jpg", "notes.txt"])
    }

    @Test func aFileThatAppearsMeanwhileIsNotOverwritten() {
        let session = open(["IMG_1001.jpg", "IMG_1002.jpg"])
        session.settings.nameMask = "new[C]"
        // After the preview, behind the tool's back; the run finds it and asks.
        memory.addFile("/photos/new2.jpg", "other")
        ui.choiceAnswers = [1]
        session.start()
        #expect(memory.contents("/photos/new2.jpg") == "other" && memory.contents("/photos/new1.jpg") == "p0")
        #expect(memory.exists("/photos/IMG_1002.jpg"))
    }

    @Test func failuresAreReportedAndStayInTheList() throws {
        try box.file("A/a.txt", "a")
        try box.file("A/b.txt", "b")
        try box.file("A/keep.txt", "k")
        left.show(box.url("A"))
        let session = open(["a.txt", "b.txt"])
        // The name of an existing file as a folder: nothing can be created below it.
        session.loadNames(fromText: "x.txt\nkeep.txt/inside.txt")
        // Names that come from a list and put a file into another folder are asked about first.
        ui.choiceAnswers = [0]
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.renamed.count == 1 && result?.failures.count == 1)
        #expect(namesOnDisk(box.url("A")) == ["b.txt", "keep.txt", "x.txt"])
        #expect(session.rows.map(\.entry.name) == ["b.txt"])
        #expect(ui.log.contains("inform: 1 file(s) could not be renamed!"))
    }

    // MARK: Undo

    @Test func undoAsksAndRestoresInReverseOrder() {
        let session = open(["IMG_*"])
        session.settings.nameMask = "Photo_[C]"
        session.start()
        // No: nothing happens.
        session.undo()
        #expect(photos.contains("Photo_1.jpg") && session.canUndo)
        #expect(
            ui.log.last
                == "choose: Test / Undo the following rename action:\nIMG_1001.jpg -> Photo_1.jpg\nIMG_1002.jpg -> Photo_2.jpg\nIMG_1003.jpg -> Photo_3.jpg"
        )
        ui.choiceAnswers = [0]
        var left: [RenamedItem]?
        session.undo { left = $0 }
        #expect(left?.isEmpty == true && photos == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"])
        #expect(!session.canUndo && !session.hasResultList)
        #expect(bench.left.names == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"])
    }

    @Test func undoWorksAfterTheToolWasClosedAndKeepsWhatFailed() {
        var session = open(["IMG_*"])
        session.settings.nameMask = "a[C]"
        session.start()
        session = open(["notes.txt"])
        session.settings.nameMask = "b"
        session.start()
        #expect(RenameStore(settings: settings).undoHistory.map(\.count) == [3, 1])
        // Another program takes one of the old names.
        memory.addFile("/photos/IMG_1002.jpg", "taken")
        // A new session, as after reopening the tool: the runs are undone one by one.
        session = open(["b.txt"])
        ui.choiceAnswers = [0, 0]
        session.undo()
        #expect(memory.exists("/photos/notes.txt") && session.canUndo)
        var left: [RenamedItem]?
        session.undo { left = $0 }
        #expect(left?.map(\.to.lastPathComponent) == ["a2.jpg"])
        #expect(photos == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "a2.jpg", "notes.txt"])
        #expect(memory.contents("/photos/IMG_1002.jpg") == "taken")
        #expect(RenameStore(settings: settings).undoHistory.map(\.count) == [1])
        #expect(ui.log.contains("inform: 1 file(s) could not be renamed back!"))
    }

    @Test func undoHistoryIsLimited() {
        settings.set("2", forKey: RenameStore.undoLimitKey)
        for round in 1...3 {
            let session = open(["notes*"])
            session.settings.nameMask = "notes\(round)"
            session.start()
        }
        #expect(RenameStore(settings: settings).undoHistory.count == 2)
        settings.set("0", forKey: RenameStore.undoLimitKey)
        let session = open(["notes*"])
        session.settings.nameMask = "final"
        session.start()
        #expect(photos.contains("final.txt") && !session.canUndo)
    }

    // MARK: The list

    @Test func orderDrivesTheCounter() {
        let session = open()
        session.settings.nameMask = "[C]"
        #expect(names(session) == ["1.jpg", "2.jpg", "3.jpg", "4.txt"])
        session.sort(by: .name, ascending: false)
        #expect(session.rows.map(\.entry.name) == ["notes.txt", "IMG_1003.jpg", "IMG_1002.jpg", "IMG_1001.jpg"])
        #expect(names(session) == ["1.txt", "2.jpg", "3.jpg", "4.jpg"])
        session.sort(by: .ext, ascending: true)
        #expect(session.rows.map(\.entry.name) == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"])
        session.sort(by: .date, ascending: false)
        #expect(session.rows.map(\.entry.name).prefix(2) == ["IMG_1003.jpg", "IMG_1002.jpg"])
        session.sort(by: .size, ascending: true)
        #expect(session.rows.first?.entry.name == "notes.txt")
        session.sort(by: .name, ascending: true)
        #expect(session.move([1], by: -1) == [0])
        #expect(
            session.rows.map(\.entry.name).prefix(2) == ["IMG_1002.jpg", "IMG_1001.jpg"]
                && names(session).first == "1.jpg")
        #expect(session.move([0], by: -1) == [0] && session.move([3], by: 1) == [3])
        #expect(session.move([0, 1], by: 1) == [1, 2])
        #expect(session.rows.map(\.entry.name) == ["IMG_1003.jpg", "IMG_1002.jpg", "IMG_1001.jpg", "notes.txt"])
        #expect(session.move([3, 0], to: 2) == [1, 2])
        #expect(session.rows.map(\.entry.name) == ["IMG_1002.jpg", "IMG_1003.jpg", "notes.txt", "IMG_1001.jpg"])
        session.remove([0, 2])
        #expect(
            session.rows.map(\.entry.name) == ["IMG_1003.jpg", "IMG_1001.jpg"] && names(session) == ["1.jpg", "2.jpg"])
        session.start()
        #expect(
            memory.contents("/photos/1.jpg") == "p2" && memory.contents("/photos/2.jpg") == "p0"
                && memory.exists("/photos/IMG_1002.jpg"))
    }

    @Test func nextStepChainsRules() {
        let session = open(["IMG_*"])
        session.settings.search = "IMG_"
        session.settings.replacement = "holiday "
        session.nextStep()
        // Nothing is renamed yet; the computed names are the old names of the next rules.
        #expect(photos.contains("IMG_1001.jpg") && session.settings == .unchanged)
        #expect(session.rows.map(\.entry.name) == ["holiday 1001.jpg", "holiday 1002.jpg", "holiday 1003.jpg"])
        #expect(session.rows.allSatisfy { $0.status == .ready })
        session.settings.nameMask = "[F][N1-7]-[N-1]"
        session.start()
        #expect(photos == ["Holiday-1.jpg", "Holiday-2.jpg", "Holiday-3.jpg", "notes.txt"])
    }

    @Test func editNamesAndLoadNamesFromAFile() throws {
        let session = open(["IMG_*"])
        session.settings.nameMask = "[N]x"
        ui.formAnswers = [.values(["names": .text("first.jpg\nsecond.jpg")])]
        session.editNames()
        if case .multilineText(let proposed)? = ui.forms.last?.first?.kind {
            #expect(proposed == "IMG_1001x.jpg\nIMG_1002x.jpg\nIMG_1003x.jpg")
        } else {
            Issue.record("the names are edited in a text field")
        }
        // A shorter list leaves the rest to the masks; the case conversion still applies.
        session.settings.letterCase = .upper
        #expect(names(session) == ["FIRST.JPG", "SECOND.JPG", "IMG_1003X.JPG"])
        session.clearGivenNames()
        #expect(names(session).first == "IMG_1001X.JPG")
        ui.formAnswers = [.cancel]
        session.editNames()
        #expect(session.givenNames == nil)

        session.settings = .unchanged
        let list = try box.file("names.txt", "a.jpg\nb.jpg\nc.jpg\n")
        var loaded = false
        session.loadNames(from: list) { loaded = true }
        #expect(loaded && names(session) == ["a.jpg", "b.jpg", "c.jpg"])
        session.loadNames(from: memory.addFile("/lists/utf16.txt", "ignored"))
        session.loadNames(from: box.url("missing.txt"))
        #expect(ui.log.last == "inform: The names cannot be loaded!")
        // Sorting ends the pairing of names and places.
        session.sort(by: .name, ascending: false)
        #expect(session.givenNames == nil)
    }

    // MARK: Settings

    @Test func savedSettings() {
        var session = open(["IMG_*"])
        session.settings.nameMask = "[N]_[C]"
        session.settings.regularExpression = true
        session.settings.counter.digits = 3
        session.save(as: "  numbered ")
        session.settings = .unchanged
        session.save(as: "Zero")
        session.save(as: " ")
        #expect(session.store.savedNames == ["numbered", "Zero"])
        #expect(
            session.load("numbered") && session.settings.nameMask == "[N]_[C]" && session.settings.counter.digits == 3)
        #expect(names(session).first == "IMG_1001_001.jpg")
        #expect(!session.load("unknown"))
        session.deleteSaved("Zero")
        #expect(RenameStore(settings: settings).savedNames == ["numbered"])

        // Reopening keeps the last settings of this run of the program…
        session.settings.nameMask = "last[C]"
        session = open(["IMG_*"])
        #expect(session.settings.nameMask == "last[C]")
        // …a name opens those settings, an unknown name the defaults…
        #expect(open(["IMG_*"], settingsName: "numbered").settings.nameMask == "[N]_[C]")
        #expect(open(["IMG_*"], settingsName: "nothing").settings == .unchanged)
        // …and so does the preference.
        settings.set("numbered", forKey: RenameStore.startupSettingsKey)
        #expect(open(["IMG_*"]).settings.regularExpression)
    }

    @Test func historiesAndTitleWords() {
        let store = RenameStore(settings: settings)
        store.remember(" a", in: .search)
        store.remember("b", in: .search)
        store.remember(" a", in: .search)
        store.remember("", in: .search)
        #expect(store.history(.search) == [" a", "b"] && store.history(.replacement).isEmpty)
        store.forget("b", in: .search)
        #expect(store.history(.search) == [" a"])
        (0..<30).forEach { store.remember("m\($0)", in: .nameMask) }
        #expect(store.history(.nameMask).count == RenameStore.historyLimit && store.history(.nameMask).first == "m29")

        settings.set("Mine:img", forKey: RenameStore.lowercaseWordsKey)
        memory.addFile("/titles/the img of img.txt")
        left.show(memory.url("/titles"))
        let session = open()
        session.settings.letterCase = .titleWords
        #expect(names(session) == ["The img Of Img.txt"])
    }
}

/// The window itself: built without being shown, to see that it holds together.
@MainActor @Suite struct MultiRenameWindow {
    @Test func windowShowsTheSessionAndFollowsIt() throws {
        _ = NSApplication.shared
        let memory = MemoryFileSystem()
        memory.addFile("/w/a.txt")
        memory.addFile("/w/b.txt")
        let box = try Sandbox()
        let bench = TestBench(plugins: [], fileSystems: [memory], left: memory.url("/w"), right: memory.url("/w"))
        let session = MultiRenameSession(
            kernel: bench.kernel, items: bench.left.model.items, store: RenameStore(settings: bench.kernel.settings),
            settings: .unchanged, logDirectory: box.url("log"), previewsInBackground: false)
        let controller = MultiRenameWindowController(kernel: bench.kernel, session: session)
        let window = try #require(controller.window)
        #expect(window.title == "Multi-Rename Tool")
        func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
            guard let view else { return [] }
            return ([view as? View].compactMap { $0 }) + view.subviews.flatMap { views(type, in: $0) }
        }
        let table = try #require(views(NSTableView.self, in: window.contentView).first)
        #expect(
            table.numberOfRows == 2
                && table.tableColumns.map(\.title) == ["Old name", "Ext.", "New name", "Size", "Date", "Location"])
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
