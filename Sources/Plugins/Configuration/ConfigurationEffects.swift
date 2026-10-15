import AppKit
import UniformTypeIdentifiers

/// What the configuration windows and commands do outside themselves: putting a window on
/// screen, a beep, the modal run of the *Choose command* dialog for an editor, the panel that
/// asks for a settings file, the About panel, the program's menu bar and windows, the clipboard, and the key presses of a shortcut being recorded. The
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
        showAbout: { NSApp?.orderFrontStandardAboutPanel(nil) },
        mainMenu: { NSApp?.mainMenu },
        windows: { NSApp?.windows ?? [] },
        pasteboard: .general,
        monitorKeys: { NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: $0) },
        removeKeyMonitor: { NSEvent.removeMonitor($0) }
    )

    /// Nothing goes on screen or sounds, a modal run ends at once, no file is chosen, there is
    /// no menu bar and no window, copies go to a pasteboard of their own, and no key is watched.
    static let silent = Self(
        present: { _ in },
        beep: {},
        runModal: { _ in },
        stopModal: {},
        chooseSettingsFile: { _, _ in nil },
        showAbout: {},
        mainMenu: { nil },
        windows: { [] },
        pasteboard: NSPasteboard.withUniqueName(),
        monitorKeys: { _ in nil },
        removeKeyMonitor: { _ in }
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
    /// The menu bar the shell built; nil before there is one.
    var mainMenu: @MainActor () -> NSMenu?
    /// The program's windows.
    var windows: @MainActor () -> [NSWindow]
    /// Where a copied command name goes: the clipboard, or a pasteboard of a test's own.
    var pasteboard: NSPasteboard
    /// Hands every key press of the program to the handler first, which returns the event to
    /// pass on or nil to swallow it (a new shortcut being pressed). Returns the monitor.
    var monitorKeys: @MainActor (@escaping (NSEvent) -> NSEvent?) -> Any?
    /// Ends a monitor of `monitorKeys`.
    var removeKeyMonitor: @MainActor (Any) -> Void

    /// The system's panel for a settings file.
    private static func filePanel(saving: Bool, _ productName: String) -> URL? {
        let panel: NSSavePanel = saving ? NSSavePanel() : NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if saving { panel.nameFieldStringValue = "\(productName) Settings.json" }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
