import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The parts of the window shell that review round 2 added or changed, by themselves: the
/// program's own threads, dialogs one after the other, the keys of menus, names on screen, the
/// button Return presses, large settings and the command line's history.
@MainActor
@Suite(.serialized)
internal struct Review2ShellPartsTests {
    /// Stands in for the window: the target of the entries of a test menu.
    @objc
    private final class MenuTarget: NSObject, NSMenuItemValidation {
        var isOffered = true
        var validated = 0
        var senders: [NSMenuItem] = []

        func validateMenuItem(_: NSMenuItem) -> Bool {
            validated += 1
            return isOffered
        }

        @objc
        func run(_ sender: Any?) {
            if let item = sender as? NSMenuItem {
                senders.append(item)
            }
        }
    }

    /// Makes the shared application, which menus and alerts need.
    internal init() {
        _ = NSApplication.shared
    }

    /// The URL `text` writes.
    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    /// The keys of the buttons of an alert.
    private func keys(_ alert: NSAlert) -> [String] {
        alert.buttons.map(\.keyEquivalent)
    }

    /// A settings store in a defaults suite and a folder of its own.
    private func makeStore() throws -> (store: UserDefaultsSettings, defaults: UserDefaults, folder: URL) {
        let suite = "afm-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        return (UserDefaultsSettings(defaults: defaults, largeFolder: folder), defaults, folder)
    }

    /// A lane runs one call at a time, a stuck lane holds up no other, and the threads are the
    /// kernel's, named after the lane while they work for it (S069; kernel request 1).
    @Test
    internal func aLaneRunsOneCallAtATimeAndAStuckLaneHoldsUpNoOther() async throws {
        let (stuck, other) = (try url("lane://host/stuck"), try url("lane://host/other"))
        let gate = DispatchSemaphore(value: 0)
        let log = Shared<[String]>([])
        Background.storage("test", at: stuck) {
            log.modify { $0.append("first on main: \(Thread.isMainThread), thread \(Thread.current.name ?? "")") }
            gate.wait()
        }
        Background.storage("test", at: stuck) { log.modify { $0.append("second") } }
        Background.storage("test", at: other) { log.modify { $0.append("other") } }
        // Another purpose at the same place is another lane.
        Background.storage("test2", at: stuck) { log.modify { $0.append("other purpose") } }
        #expect(await PanelWait.until { log.value.count == 3 })
        #expect(Set(log.value) == ["first on main: false, thread afm.test", "other", "other purpose"])
        #expect(Background.isBusy("test", at: stuck) && !Background.isBusy("test", at: other))
        gate.signal()
        #expect(await PanelWait.until { log.value.count == 4 && !Background.isBusy("test", at: stuck) })
        #expect(log.value.last == "second")
        let after = Shared("")
        BlockingCalls.run { after.value = Thread.current.name ?? "" }
        #expect(await PanelWait.until { !after.value.isEmpty } && after.value == "AFM.Blocking")
    }

    /// Results come back through the run loop, in order; something large is let go of elsewhere.
    @Test
    internal func resultsComeBackThroughTheRunLoopAndInOrder() async {
        var got: [Int] = []
        for number in 0..<20 {
            Background.storage("order", at: URL(fileURLWithPath: "/order"), work: { number }, then: { got.append($0) })
        }
        var computed = 0
        Background.compute(work: { (0..<1_000).reduce(0, +) }, then: { computed = $0 })
        #expect(await PanelWait.until { got.count == 20 && computed != 0 })
        #expect(got == Array(0..<20) && computed == 499_500)
        var list: [Int]? = Array(0..<100_000)
        Background.release(&list)
        #expect(list == nil)
    }

    /// Dialogs come one after the other and not from inside the main queue.
    @Test
    internal func dialogsComeOneAfterTheOtherAndNotFromInsideTheMainQueue() async {
        var log: [String] = []
        var queued = false
        MainLoop.dialog {
            log.append("first up")
            // A dialog runs the loop itself for a while; what was sent to the main queue meanwhile arrives.
            DispatchQueue.main.async { queued = true }
            let until = Date().addingTimeInterval(5)
            while !queued, Date() < until {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            log.append("first down, queue served: \(queued)")
        }
        MainLoop.dialog { log.append("second") }
        #expect(await PanelWait.until { log.count == 3 })
        #expect(log == ["first up", "first down, queue served: true", "second"])
    }

    /// The key of a menu entry runs that entry and checks no other; a menu about to be shown
    /// brings its own entries up to date, and no other menu's (S004, S033).
    @Test
    internal func theKeyOfAMenuEntryRunsThatEntryAndChecksNoOther() throws {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        var asked = 0
        let enabled = {
            asked += 1
            return true
        }
        kernel.commands.register(Command("test_Bound", "Bound", [.f(9), .cmd("j")]), enabled: enabled, checked: { false }) {
            // Runs through the menu entry.
        }
        for index in 0..<40 {
            kernel.commands.register(Command(CommandID(rawValue: "test_Other\(index)"), "Other \(index)"), enabled: enabled, checked: { false }) {
                // Runs through the menu entry.
            }
        }
        let target = MenuTarget()
        let (menu, inner, bar) = (NSMenu(title: "Commands"), NSMenu(title: "More"), NSMenu())
        for command in kernel.commands.all {
            let item = MenuBuilder.item(command, keys: kernel.keyBindings)
            (item.target, item.action) = (target, #selector(MenuTarget.run(_:)))
            (command.id == "test_Bound" ? inner : menu).addItem(item)
        }
        let undo = NSMenuItem(title: "Undo", action: #selector(MenuTarget.run(_:)), keyEquivalent: "z")
        undo.target = target
        menu.addItem(undo)
        for (holder, submenu) in [(NSMenuItem(title: "More", action: nil, keyEquivalent: ""), inner), (NSMenuItem(title: "Commands", action: nil, keyEquivalent: ""), menu)] {
            holder.submenu = submenu
            (submenu === inner ? menu : bar).addItem(holder)
        }
        let keys = MenuKeys(kernel: kernel)
        keys.answer(for: menu)
        let nine = String(try #require(UnicodeScalar(NSF9FunctionKey)))
        #expect(!bar.performKeyEquivalent(with: PanelProgram.key(0, "a", [])) && !bar.performKeyEquivalent(with: PanelProgram.key(40, "k", .command)))
        #expect(keys.lookups > 0 && target.validated == 0 && asked == 0 && target.senders.isEmpty)
        #expect(bar.performKeyEquivalent(with: PanelProgram.key(101, nine, [])))
        #expect(target.senders.map(\.title) == ["Bound"] && target.validated == 1 && keys.validations == 1 && asked == 0)
        #expect(bar.performKeyEquivalent(with: PanelProgram.key(6, "z", .command)) && bar.performKeyEquivalent(with: PanelProgram.key(6, "я", .command)))
        #expect(target.senders.map(\.title) == ["Bound", "Undo", "Undo"])
        #expect(!bar.performKeyEquivalent(with: PanelProgram.key(38, "j", .command)) && target.validated == 3)
        target.isOffered = false
        _ = bar.performKeyEquivalent(with: PanelProgram.key(101, nine, []))
        #expect(target.senders.count == 3 && target.validated > 3 && target.validated <= 3 + 6 && inner.items.first?.isEnabled == false)
        target.isOffered = true
        var before = target.validated
        keys.menuNeedsUpdate(inner)
        #expect(target.validated == before + 1 && inner.items.first?.isEnabled == true)
        before = target.validated
        keys.menuNeedsUpdate(menu)
        #expect(target.validated == before + 41 && menu.items.allSatisfy(\.isEnabled))
    }

    /// Names that could mislead are shown with every character visible, one for one (S066).
    @Test
    internal func namesThatCouldMisleadAreShownWithEveryCharacterVisible() {
        #expect(DisplayText.clean("report.txt") == "report.txt" && DisplayText.clean("Übergrößen – 日本.txt") == "Übergrößen – 日本.txt")
        #expect(DisplayText.clean("invoice\u{202E}fdp.exe") == "invoice\u{FFFD}fdp.exe")
        #expect(DisplayText.clean("two\nlines\ttab\u{7}") == "two\u{240A}lines\u{2409}tab\u{2407}")
        #expect(DisplayText.clean("two\nlines \u{202E}x", keepingLines: true) == "two\nlines \u{FFFD}x")
        let name = "a\u{2066}b\u{85}c\u{200F}d"
        #expect(DisplayText.clean(name).utf16.count == name.utf16.count)
    }

    /// Return never answers a critical question with Yes; the caller says which button Return
    /// presses, or that none does (F055, N030; fileops 5, network 3, kernel 4).
    @Test
    internal func returnNeverAnswersACriticalQuestionWithYes() {
        let interaction = AlertInteraction()
        func question(_ buttons: [String], _ style: QuestionStyle, _ defaultButton: Int?) -> NSAlert {
            interaction.makeQuestion("?", detail: "", buttons: buttons, style: style, defaultButton: defaultButton)
        }
        #expect(AlertInteraction.defaultButton(for: .warning, of: ["Replace", "Skip", "Cancel"]) == 0)
        #expect(keys(question(["Replace", "Skip", "Cancel"], .warning, 0)) == ["\r", "", "\u{1b}"])
        #expect(AlertInteraction.defaultButton(for: .critical, of: ["Yes", "No"]) == 1)
        let critical = question(["Yes", "No"], .critical, 1)
        #expect(keys(critical) == ["", "\r"] && critical.alertStyle == .critical)
        #expect(AlertInteraction.defaultButton(for: .critical, of: ["OK"]) == 0 && AlertInteraction.defaultButton(for: .critical, of: []) == nil)
        #expect(keys(question(["Overwrite", "Skip", "Cancel"], .warning, 1)) == ["", "\r", "\u{1b}"])
        let none = question(["Trust", "Cancel"], .critical, nil)
        #expect(keys(none) == ["", "\u{1b}"] && none.window.initialFirstResponder === none.buttons.last)
        let titled = question(["Cancel", "Don't Save", "Save"], .warning, 2)
        #expect(keys(titled) == ["", "", "\r"] && titled.buttons.allSatisfy { $0.keyEquivalentModifierMask.isEmpty })
        #expect(keys(question(["A", "B"], .information, 7)) == ["", "\u{1b}"])
        let named = interaction.makeQuestion("Delete a\u{202E}txt.exe?", detail: "", buttons: ["Delete\u{0007}", "Keep"], style: .warning, defaultButton: 1)
        #expect(named.messageText == "Delete a\u{FFFD}txt.exe?" && named.buttons[0].title == "Delete\u{2407}")
    }

    /// Large values are kept in files of their own, written in the background, found by the next
    /// store, moved out of the defaults, and never named outside their folder (find 6, kernel 5).
    @Test
    internal func largeValuesAreKeptInFilesOfTheirOwn() throws {
        let (store, defaults, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = Data(repeating: 0x41, count: 3_000_000)
        store.setLarge(big, forKey: "multiRename.undo")
        #expect(store.largeData(forKey: "multiRename.undo") == big && store.waitForWrites(atMost: 60))
        let file = try #require(store.largeFile(forKey: "multiRename.undo"))
        #expect((try? Data(contentsOf: file)) == big && defaults.object(forKey: "multiRename.undo") == nil)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        let next = UserDefaultsSettings(defaults: defaults, largeFolder: folder)
        #expect(next.largeData(forKey: "multiRename.undo") == big && next.data(forKey: "multiRename.undo") == nil)
        for index in 0..<50 {
            store.setLarge(Data("v\(index)".utf8), forKey: "multiRename.undo")
        }
        #expect(store.waitForWrites(atMost: 60) && (try? Data(contentsOf: file)) == Data("v49".utf8))
        store.setLarge(nil, forKey: "multiRename.undo")
        #expect(store.largeData(forKey: "multiRename.undo") == nil && store.waitForWrites(atMost: 60))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        defaults.set(Data("old".utf8), forKey: "history")
        #expect(store.largeData(forKey: "history") == Data("old".utf8))
        store.setLarge(Data("new".utf8), forKey: "history")
        #expect(store.waitForWrites(atMost: 60) && defaults.object(forKey: "history") == nil)
        for key in ["../../escape", "/etc/passwd", "..", ".", "a/b", ".hidden", "with space", "é", String(repeating: "x", count: 1_000)] {
            let named = try #require(store.largeFile(forKey: key))
            #expect(named.deletingLastPathComponent().path == folder.path && !named.lastPathComponent.hasPrefix("."))
            #expect(named.lastPathComponent.utf8.count <= 255 && named.lastPathComponent.hasSuffix(".data"))
        }
        let plain = UserDefaultsSettings(defaults: defaults, largeFolder: nil)
        plain.setLarge(Data("x".utf8), forKey: "k")
        #expect(plain.largeFile(forKey: "k") == nil && defaults.data(forKey: "k") == Data("x".utf8))
    }

    /// The command line's history keeps no line that begins with a blank, and nothing when it
    /// is switched off; what an earlier session remembered goes then (C053).
    @Test
    internal func theHistoryKeepsNoLineThatBeginsWithABlankAndNothingWhenSwitchedOff() {
        let settings = MemorySettings()
        let history = CommandLineHistory(settings: settings)
        for line in ["ls -l", " export TOKEN=secret", "\tmysql -psecret", "ls -l  "] {
            history.add(line)
        }
        #expect(history.entries == ["ls -l"] && CommandLineHistory.isPrivate(" x") && !CommandLineHistory.isPrivate("x "))
        #expect(history.isRecording)
        settings.set(false, forKey: CommandLineHistory.recordKey)
        history.add("pwd")
        #expect(history.entries.isEmpty && settings.data(forKey: CommandLineHistory.settingsKey) == nil)
        settings.set(["old line"], forKey: CommandLineHistory.settingsKey)
        #expect(CommandLineHistory(settings: settings).entries.isEmpty && settings.data(forKey: CommandLineHistory.settingsKey) == nil)
    }
}
