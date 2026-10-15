import AppKit
import UniformTypeIdentifiers

/// What the configuration windows and commands do outside themselves.
///
/// That is putting a window on screen, a beep, the modal run of the *Choose command* dialog for
/// an editor, the panel that asks for a settings file, the About panel, the program's menu bar
/// and windows, the clipboard, and the key presses of a shortcut being recorded. The program
/// uses the system's; a plugin that launches no applications (the tests') uses the silent side,
/// and tests put recorders in its place, so that nothing sounds or opens on the desktop.
///
/// Main thread only, like the windows.
@MainActor
internal struct ConfigurationEffects {
    /// The system's own.
    internal static let system = Self(
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

    /// Nothing goes on screen or sounds, and nothing is chosen.
    ///
    /// A modal run ends at once, there is no menu bar and no window, copies go to a pasteboard
    /// of their own, and no key is watched.
    internal static let silent = Self(
        present: { _ in
            // Not on screen.
        },
        beep: {
            // Silent.
        },
        runModal: { _ in
            // Ends at once.
        },
        stopModal: {
            // Nothing runs modally.
        },
        chooseSettingsFile: { _, _ in nil },
        showAbout: {
            // Not on screen.
        },
        mainMenu: { nil },
        windows: { [] },
        pasteboard: NSPasteboard.withUniqueName(),
        monitorKeys: { _ in nil },
        removeKeyMonitor: { _ in
            // Nothing is watched.
        }
    )

    /// Puts a window on screen and in front.
    internal var present: @MainActor (NSWindowController) -> Void
    /// Tells the user that a button has nothing to act on.
    internal var beep: @MainActor () -> Void
    /// Shows the window and runs it modally until `stopModal`.
    internal var runModal: @MainActor (NSWindow) -> Void
    /// Ends the modal run of `runModal`.
    internal var stopModal: @MainActor () -> Void
    /// Asks for the settings file to write (`saving`) or read; nil when the user cancels.
    internal var chooseSettingsFile: @MainActor (_ saving: Bool, _ productName: String) -> URL?
    /// Shows the program's About panel.
    internal var showAbout: @MainActor () -> Void
    /// The menu bar the shell built; nil before there is one.
    internal var mainMenu: @MainActor () -> NSMenu?
    /// The program's windows.
    internal var windows: @MainActor () -> [NSWindow]
    /// Where a copied command name goes: the clipboard, or a pasteboard of a test's own.
    internal var pasteboard: NSPasteboard
    /// Hands every key press of the program to the handler first.
    ///
    /// The handler returns the event to pass on, or nil to swallow it (a new shortcut being
    /// pressed). Returns the monitor.
    internal var monitorKeys: @MainActor (@escaping (NSEvent) -> NSEvent?) -> Any?
    /// Ends a monitor of `monitorKeys`.
    internal var removeKeyMonitor: @MainActor (Any) -> Void

    /// The system's panel for a settings file.
    private static func filePanel(saving: Bool, _ productName: String) -> URL? {
        let panel: NSSavePanel = saving ? NSSavePanel() : NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if saving { panel.nameFieldStringValue = "\(productName) Settings.json" }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
