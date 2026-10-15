import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The program's questions as standard alerts, built and answered without being shown.
///
/// Showing them (`runModal`) is the one line the UI tests cover; no unit test puts a modal
/// window on the screen.
@MainActor
@Suite
internal struct AppAlertTests {
    /// Makes sure AppKit is there for the alerts.
    internal init() {
        _ = NSApplication.shared
    }

    /// The button that ended a question is its answer, counted from the first.
    @Test
    internal func theButtonPressedIsTheAnswer() {
        #expect(AlertInteraction.index(of: .alertFirstButtonReturn) == 0)
        #expect(AlertInteraction.index(of: .alertThirdButtonReturn) == 2)
    }

    /// A prompt starts with the given text and answers with what is typed, or nil when cancelled.
    @Test
    internal func aPromptAnswersWithWhatWasTyped() {
        let (alert, field) = AlertInteraction().makePrompt("New name:", value: "old.txt", detail: "In docs")
        #expect(alert.buttons.map(\.title) == ["OK", "Cancel"] && field.stringValue == "old.txt")
        #expect(alert.messageText == "New name:" && alert.window.initialFirstResponder === field)
        field.stringValue = "renamed.txt"
        #expect(AlertInteraction.text(of: field, after: .alertFirstButtonReturn) == "renamed.txt")
        #expect(AlertInteraction.text(of: field, after: .alertSecondButtonReturn) == nil)
    }

    /// Esc is watched for only where the last button is Return's; Esc in the alert presses it,
    /// any other key, or Esc in another window, goes on as it came.
    @Test
    internal func escPressesTheLastButtonEvenWhereReturnDoesToo() throws {
        let interaction = AlertInteraction()
        let plain = interaction.makeQuestion(
            "Go?",
            detail: "",
            buttons: ["Stop", "Go"],
            style: .warning,
            defaultButton: 0
        )
        #expect(interaction.escapeMonitor(for: plain) == nil)
        let alert = interaction.makeQuestion(
            "Go?",
            detail: "",
            buttons: ["Stop", "Go"],
            style: .warning,
            defaultButton: 1
        )
        let monitor = try #require(interaction.escapeMonitor(for: alert))
        NSEvent.removeMonitor(monitor)
        let letter = try AppRun.keyEvent(0, "a", [])
        #expect(AlertInteraction.pressLastButton(of: alert, for: letter) === letter)
        let elsewhere = try AppRun.keyEvent(53, "\u{1b}", [])
        #expect(AlertInteraction.pressLastButton(of: alert, for: elsewhere) === elsewhere)
        #expect(AlertInteraction.pressLastButton(of: nil, for: elsewhere) === elsewhere)
        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: alert.window.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        var pressed = 0
        let last = try #require(alert.buttons.last)
        let counter = AppActionCounter { pressed += 1 }
        (last.target, last.action) = (counter, #selector(AppActionCounter.run(_:)))
        #expect(alert.window.windowNumber != 0)
        #expect(AlertInteraction.pressLastButton(of: alert, for: escape) == nil && pressed == 1)
    }
}
