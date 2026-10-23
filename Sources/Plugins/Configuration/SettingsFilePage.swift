import AFMKernel
import AppKit

/// Export, import and reset of the settings as a whole (spec 19 › What is saved when, adapted:
/// the Mac keeps settings in the preferences system, not in a file the user can copy).
internal final class SettingsFilePage: NSObject, OptionsPage {
    /// The page's name, "Settings File".
    internal let title = "Settings File"
    /// What the page says about the settings, and the buttons that run the export, the import and the reset.
    internal let view: NSView
    /// Always false: the page's buttons act at once, nothing is pending.
    internal let isChanged = false
    /// Set by the window like on every page; this one never calls it, as nothing on it is pending.
    internal var onEdit: (() -> Void)?

    /// A page whose buttons run the center's export, import and reset commands.
    internal init(center: ConfigurationCenter) {
        let commands = center.kernel.commands
        let buttons = filledStack(
            [
                ActionButton("Export Settings…") { commands.perform(ConfigurationPlugin.exportSettings) },
                ActionButton("Import Settings…") { commands.perform(ConfigurationPlugin.importSettings) },
                ActionButton("Reset All Settings…") { commands.perform(ConfigurationPlugin.resetSettings) },
                spacer()
            ],
            vertical: false,
            spacing: 8
        )
        view = filledStack(
            [
                NSTextField(
                    wrappingLabelWithString:
                        "Settings are stored the moment they change; there is nothing to save by hand. "
                        + "To keep a copy or to take the settings to another Mac, export them to a file."
                ),
                buttons,
                OptionsLayout.note(
                    "The file holds the options of all pages, the key bindings, the button bar, the user commands, "
                        + "the Start menu, the directory hotlist and the panels' tabs. Histories (typed command lines, "
                        + "visited folders) and saved connections are in it only if you ask for them; passwords never "
                        + "are. Only you can read the file. Window positions are kept by macOS and are not in it.\n"
                        + "An import shows what it would change first. User commands, key bindings, programs, "
                        + "connections and trusted certificates from a file are taken over only when you tick them."
                ),
                spacer()
            ],
            vertical: true,
            spacing: 12
        )
        super.init()
    }

    /// Nothing to store: the buttons act at once.
    internal func commit() {
        // Nothing is pending on this page.
    }

    /// Nothing to drop: the buttons act at once.
    internal func discard() {
        // Nothing is pending on this page.
    }
}
