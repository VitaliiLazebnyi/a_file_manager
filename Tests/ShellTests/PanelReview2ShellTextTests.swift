import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The parts of the window shell that review round 2 added or changed, as the user reads them:
/// names on screen, the button Return presses, large settings and the command line's history.
@MainActor
@Suite
internal struct PanelReview2ShellTextTests {
    /// Makes the shared application, which alerts need.
    internal init() {
        _ = NSApplication.shared
    }

    /// The keys of the buttons of an alert.
    private func keys(_ alert: NSAlert) -> [String] {
        alert.buttons.map(\.keyEquivalent)
    }

    /// A defaults suite and a folder of its own, for a settings store.
    private func makeStoreParts() throws -> (defaults: UserDefaults, folder: URL) {
        let suite = "afm-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true))
    }

    /// Names that could mislead are shown with every character visible, one for one (S066).
    @Test
    internal func namesThatCouldMisleadAreShownWithEveryCharacterVisible() {
        #expect(
            DisplayText.clean("report.txt") == "report.txt"
                && DisplayText.clean("Übergrößen – 日本.txt") == "Übergrößen – 日本.txt"
        )
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
        #expect(
            AlertInteraction.defaultButton(for: .critical, of: ["OK"]) == 0
                && AlertInteraction.defaultButton(for: .critical, of: []) == nil
        )
        #expect(keys(question(["Overwrite", "Skip", "Cancel"], .warning, 1)) == ["", "\r", "\u{1b}"])
        let none = question(["Trust", "Cancel"], .critical, nil)
        #expect(keys(none) == ["", "\u{1b}"] && none.window.initialFirstResponder === none.buttons.last)
        let titled = question(["Cancel", "Don't Save", "Save"], .warning, 2)
        #expect(keys(titled) == ["", "", "\r"] && titled.buttons.allSatisfy(\.keyEquivalentModifierMask.isEmpty))
        #expect(keys(question(["A", "B"], .information, 7)) == ["", "\u{1b}"])
        let named = interaction.makeQuestion(
            "Delete a\u{202E}txt.exe?",
            detail: "",
            buttons: ["Delete\u{0007}", "Keep"],
            style: .warning,
            defaultButton: 1
        )
        #expect(named.messageText == "Delete a\u{FFFD}txt.exe?" && named.buttons[0].title == "Delete\u{2407}")
    }

    /// Large values are kept in files of their own, written in the background, found by the next
    /// store, moved out of the defaults, and never named outside their folder (find 6, kernel 5).
    @Test
    internal func largeValuesAreKeptInFilesOfTheirOwn() throws {
        let (defaults, folder) = try makeStoreParts()
        let store = UserDefaultsSettings(defaults: defaults, largeFolder: folder)
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
        for key in [
            "../../escape", "/etc/passwd", "..", ".", "a/b", ".hidden", "with space", "é",
            String(repeating: "x", count: 1_000)
        ] {
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
        #expect(
            history.entries == ["ls -l"] && CommandLineHistory.isPrivate(" x") && !CommandLineHistory.isPrivate("x ")
        )
        #expect(history.isRecording)
        settings.set(false, forKey: CommandLineHistory.recordKey)
        history.add("pwd")
        #expect(history.entries.isEmpty && settings.data(forKey: CommandLineHistory.settingsKey) == nil)
        settings.set(["old line"], forKey: CommandLineHistory.settingsKey)
        #expect(
            CommandLineHistory(settings: settings).entries.isEmpty
                && settings.data(forKey: CommandLineHistory.settingsKey) == nil
        )
    }
}
