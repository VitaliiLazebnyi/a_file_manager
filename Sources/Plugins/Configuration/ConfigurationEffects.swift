import AppKit
import UniformTypeIdentifiers

/// What the configuration windows and commands do outside themselves: putting a window on
/// screen, a beep, the modal run of the *Choose command* dialog for an editor, the panel that
/// asks for a settings file and the About panel. The
/// program uses the system's; a plugin that launches no applications (the tests') uses the
/// silent side, and tests put recorders in its place, so that nothing sounds or opens on the
/// desktop.
///
/// Main thread only, like the windows.
@MainActor
struct ConfigurationEffects {
    /// The system's own.
    static let system = Self(
        present: { $0.showWindow(nil) },
        beep: { NSSound.beep() },
        runModal: { _ = NSApp.runModal(for: $0) },
        stopModal: { NSApp.stopModal() },
        chooseSettingsFile: { saving, productName in Self.filePanel(saving: saving, productName) },
        showAbout: { NSApp?.orderFrontStandardAboutPanel(nil) }
    )

    /// Nothing goes on screen or sounds, a modal run ends at once, and no file is chosen.
    static let silent = Self(
        present: { _ in },
        beep: {},
        runModal: { _ in },
        stopModal: {},
        chooseSettingsFile: { _, _ in nil },
        showAbout: {}
    )

    /// Puts a window on screen and in front.
    var present: @MainActor (NSWindowController) -> Void

    /// Tells the user that a button has nothing to act on.
    var beep: @MainActor () -> Void
    /// Shows the window and runs it modally until `stopModal`.
    var runModal: @MainActor (NSWindow) -> Void
    /// Ends the modal run of `runModal`.
    var stopModal: @MainActor () -> Void
    /// Asks for the settings file to write (`saving`) or read; nil when the user cancels.
    var chooseSettingsFile: @MainActor (_ saving: Bool, _ productName: String) -> URL?
    /// Shows the program's About panel.
    var showAbout: @MainActor () -> Void

    /// The system's panel for a settings file.
    private static func filePanel(saving: Bool, _ productName: String) -> URL? {
        let panel: NSSavePanel = saving ? NSSavePanel() : NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if saving { panel.nameFieldStringValue = "\(productName) Settings.json" }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
