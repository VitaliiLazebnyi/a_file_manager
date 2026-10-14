import AFMKernel
import Foundation

/// What the main window shows around the panels and how the panels are arranged
/// (spec 02 › Showing and hiding regions, 02 › Panel divider and arrangement). Every value is
/// kept in the settings the moment it changes, so the next start finds the window as it was
/// left. Main thread only.
final class WindowLayout {
    /// A part of the window the user can switch off.
    enum Region: String, CaseIterable {
        case buttonBar, driveButtons, commandLine, functionKeys

        var settingsKey: String {
            switch self {
            case .buttonBar: return "window.showButtonBar"
            case .driveButtons: return "window.showDriveButtons"
            case .commandLine: return "window.showCommandLine"
            case .functionKeys: return "window.showFunctionKeys"
            }
        }

        /// As in Total Commander, everything is shown at first except the drive buttons.
        var isShownByDefault: Bool { self != .driveButtons }

        var caption: String {
            switch self {
            case .buttonBar: return "Button Bar"
            case .driveButtons: return "Drive Buttons"
            case .commandLine: return "Command Line"
            case .functionKeys: return "Function Key Buttons"
            }
        }
    }

    static let stackedKey = "window.panelsStacked"
    static let dividerKey = "window.divider"
    static let sourceKey = "window.sourcePanel"
    static let frameKey = "window.frame"
    static let fullScreenKey = "window.fullScreen"
    static let titleExtraKey = "window.titleExtraText"

    private let settings: SettingsStore
    /// Called after a value that changes the look of the window was set.
    var onChange: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func isVisible(_ region: Region) -> Bool {
        settings.flag(region.settingsKey, default: region.isShownByDefault)
    }

    func setVisible(_ region: Region, _ visible: Bool) {
        guard visible != isVisible(region) else { return }
        settings.set(visible, forKey: region.settingsKey)
        onChange?()
    }

    /// The panels one above the other instead of side by side (`cm_VerticalPanels`).
    var isStacked: Bool {
        get { settings.flag(Self.stackedKey, default: false) }
        set {
            guard newValue != isStacked else { return }
            settings.set(newValue, forKey: Self.stackedKey)
            onChange?()
        }
    }

    /// The share of the left (or upper) panel in thousandths, as the specification stores it
    /// (`Divider=500`). A panel never gets less than a tenth.
    var divider: Int {
        get { Self.clamped(settings.index(Self.dividerKey, default: 500)) }
        set {
            guard Self.clamped(newValue) != divider else { return }
            settings.set(Self.clamped(newValue), forKey: Self.dividerKey)
            onChange?()
        }
    }

    static func clamped(_ divider: Int) -> Int { min(900, max(100, divider)) }

    /// Keeps the position the user dragged the divider to. The window already shows it, so
    /// nothing is redrawn.
    func rememberDivider(_ divider: Int) {
        settings.set(Self.clamped(divider), forKey: Self.dividerKey)
    }

    /// Whether the right panel was the source when the window was last used.
    var sourceIsRight: Bool {
        get { settings.text(Self.sourceKey, default: "left") == "right" }
        set { settings.set(newValue ? "right" : "left", forKey: Self.sourceKey) }
    }

    /// Position and size of the window outside full-screen mode, in the form `NSWindow` reads.
    var frame: String? {
        get { settings.value(String.self, forKey: Self.frameKey) }
        set { if let newValue { settings.set(newValue, forKey: Self.frameKey) } }
    }

    var isFullScreen: Bool {
        get { settings.flag(Self.fullScreenKey, default: false) }
        set { settings.set(newValue, forKey: Self.fullScreenKey) }
    }

    /// The user's addition to the window title (`TitleExtraText`).
    var titleExtra: String { settings.text(Self.titleExtraKey, default: "") }

    /// The title of the main window (spec 01 › Window title): the program's name and version
    /// in place of `Total Commander (x64) 11.58`. The user's extra text goes in front when it
    /// starts with `*` or `-`, behind when it starts with `$`. There is no registration note
    /// and no instance number: a Mac program runs once.
    static func title(productName: String, version: String?, extra: String) -> String {
        var title = productName
        if let version, !version.isEmpty { title += " " + version }
        guard let mark = extra.first else { return title }
        let text = String(extra.dropFirst())
        guard !text.isEmpty else { return title }
        switch mark {
        case "*", "-": return text + " " + title
        case "$": return title + " " + text
        default: return title
        }
    }

    /// The page of the configuration dialog for these settings (spec 13 › Layout page).
    func preferencePage() -> PreferencePage {
        var preferences = Region.allCases.map {
            Preference($0.settingsKey, "Show \($0.caption.lowercased())", .flag(default: $0.isShownByDefault))
        }
        preferences.append(Preference(Self.stackedKey, "Panels one above the other", .flag(default: false)))
        preferences.append(
            Preference(
                BarButton.iconSizeKey, "Size of the button bar's pictures",
                .choice(BarButton.iconSizeNames, default: BarButton.defaultIconSize)))
        preferences.append(
            Preference(
                Self.titleExtraKey, "Extra text in the window title (*text or $text)", .text(default: "")))
        return PreferencePage(title: "Layout", preferences: preferences) { [weak self] in self?.onChange?() }
    }
}
