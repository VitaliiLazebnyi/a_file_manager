import AppKit

/// What the compare window does outside itself: a beep, the panel to choose a file, the font panel and the
/// clipboard. The window of the program uses the system's; tests put recorders in their place, so that nothing
/// sounds or opens on the desktop.
///
/// Main thread only, like the window.
@MainActor
internal struct CompareWindowEffects {
    /// The system's own.
    internal static let system = Self(
        beep: { NSSound.beep() },
        chooseFile: { window, chosen in Self.openPanel(for: window, chosen) },
        showFontPanel: { NSFontManager.shared.orderFrontFontPanel($0) },
        pasteboard: .general
    )

    /// Tells the user that there is nothing more to go to or nothing was found.
    internal var beep: @MainActor () -> Void
    /// Asks for a file in a sheet of the window; nil when the user cancels.
    internal var chooseFile: @MainActor (NSWindow, @escaping @MainActor (URL?) -> Void) -> Void
    /// Shows the font panel for the window's controller, which takes `changeFont` from it.
    internal var showFontPanel: @MainActor (NSWindowController) -> Void
    /// Where copied lines go.
    internal var pasteboard: NSPasteboard

    /// The system's panel for choosing one file, as a sheet of `window`.
    private static func openPanel(for window: NSWindow, _ chosen: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in chosen(response == .OK ? panel.url : nil) }
    }
}
