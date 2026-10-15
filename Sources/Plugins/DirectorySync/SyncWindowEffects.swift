import AppKit

/// What the Synchronize directories window does outside itself: the panel that chooses a folder and the pop-up of the saved sets. The program uses the system's; tests put recorders
/// in their place, so that nothing opens on the desktop or waits for the mouse.
///
/// Main thread only, like the window.
@MainActor
struct SyncWindowEffects {
    /// The system's own.
    static let system = Self(
        chooseFolder: { window, chosen in Self.folderPanel(for: window, chosen) },
        showMenu: { $0.performClick(nil) }
    )

    /// Asks for a folder in a sheet of the window; nil when the user cancels.
    var chooseFolder: @MainActor (NSWindow, @escaping @MainActor (URL?) -> Void) -> Void
    /// Opens the menu of a pop-up button, as a click on it does.
    var showMenu: @MainActor (NSPopUpButton) -> Void

    /// The system's panel for choosing one folder, as a sheet of `window`.
    private static func folderPanel(for window: NSWindow, _ chosen: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.beginSheetModal(for: window) { response in chosen(response == .OK ? panel.url : nil) }
    }
}
