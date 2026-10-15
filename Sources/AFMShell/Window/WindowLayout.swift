import AFMKernel
import Foundation

/// What the main window shows around the panels and how the panels are arranged.
///
/// Spec 02 › Showing and hiding regions, 02 › Panel divider and arrangement. Every value is
/// kept in the settings the moment it changes, so the next start finds the window as it was
/// left. Main thread only.
@MainActor
internal final class WindowLayout {
    /// A part of the window the user can switch off.
    internal enum Region: CaseIterable {
        /// The button bar above the panels.
        case buttonBar
        /// The drive buttons below the button bar.
        case driveButtons
        /// The command line below the panels.
        case commandLine
        /// The function-key bar at the bottom.
        case functionKeys

        /// The settings key of whether the region is shown.
        internal var settingsKey: String {
            switch self {
            case .buttonBar:
                return "window.showButtonBar"

            case .driveButtons:
                return "window.showDriveButtons"

            case .commandLine:
                return "window.showCommandLine"

            case .functionKeys:
                return "window.showFunctionKeys"
            }
        }

        /// As in Total Commander, everything is shown at first except the drive buttons.
        internal var isShownByDefault: Bool { self != .driveButtons }

        /// The region's name, for its command and its preference.
        internal var caption: String {
            switch self {
            case .buttonBar:
                return "Button Bar"

            case .driveButtons:
                return "Drive Buttons"

            case .commandLine:
                return "Command Line"

            case .functionKeys:
                return "Function Key Buttons"
            }
        }
    }

    /// Settings key: the panels one above the other.
    internal static let stackedKey = "window.panelsStacked"
    /// Settings key: the share of the left panel.
    internal static let dividerKey = "window.divider"
    /// Settings key: which panel was the source.
    internal static let sourceKey = "window.sourcePanel"
    /// Settings key: where the window was.
    internal static let frameKey = "window.frame"
    /// Settings key: whether the window was in full-screen mode.
    internal static let fullScreenKey = "window.fullScreen"
    /// Settings key: the user's addition to the window title.
    internal static let titleExtraKey = "window.titleExtraText"

    /// Called after a value that changes the look of the window was set.
    internal var onChange: (() -> Void)?
    /// Where the values are kept.
    private let settings: any SettingsStore

    /// The panels one above the other instead of side by side (`cm_VerticalPanels`).
    internal var isStacked: Bool {
        get { settings.flag(Self.stackedKey, default: false) }
        set {
            guard newValue != isStacked else {
                return
            }
            settings.set(newValue, forKey: Self.stackedKey)
            onChange?()
        }
    }

    /// The share of the left (or upper) panel in thousandths.
    ///
    /// As the specification stores it (`Divider=500`). A panel never gets less than a tenth.
    internal var divider: Int {
        get { Self.clamped(settings.index(Self.dividerKey, default: 500)) }
        set {
            guard Self.clamped(newValue) != divider else {
                return
            }
            settings.set(Self.clamped(newValue), forKey: Self.dividerKey)
            onChange?()
        }
    }

    /// Whether the right panel was the source when the window was last used.
    internal var sourceIsRight: Bool {
        get { settings.text(Self.sourceKey, default: "left") == "right" }
        set { settings.set(newValue ? "right" : "left", forKey: Self.sourceKey) }
    }

    /// Position and size of the window outside full-screen mode, in the form `NSWindow` reads.
    ///
    /// Nil is never stored: the last frame stays.
    internal var frame: String? {
        get { settings.value(String.self, forKey: Self.frameKey) }
        set {
            if let newValue {
                settings.set(newValue, forKey: Self.frameKey)
            }
        }
    }

    /// Whether the window was left in full-screen mode.
    internal var isFullScreen: Bool {
        get { settings.flag(Self.fullScreenKey, default: false) }
        set { settings.set(newValue, forKey: Self.fullScreenKey) }
    }

    /// The user's addition to the window title (`TitleExtraText`).
    internal var titleExtra: String { settings.text(Self.titleExtraKey, default: "") }

    /// The layout kept in `settings`.
    internal init(settings: any SettingsStore) {
        self.settings = settings
    }

    /// `divider` within its limits: a tenth to nine tenths.
    internal static func clamped(_ divider: Int) -> Int { min(900, max(100, divider)) }

    /// The title of the main window (spec 01 › Window title).
    ///
    /// The program's name and version in place of `Total Commander (x64) 11.58`. The user's
    /// extra text goes in front when it starts with `*` or `-`, behind when it starts with `$`.
    /// There is no registration note and no instance number: a Mac program runs once.
    internal static func title(productName: String, version: String?, extra: String) -> String {
        var title = productName
        if let version, !version.isEmpty {
            title += " " + version
        }
        guard let mark = extra.first, extra.count > 1 else {
            return title
        }
        let text = String(extra.dropFirst())
        switch mark {
        case "*", "-":
            return text + " " + title

        case "$":
            return title + " " + text

        default:
            return title
        }
    }

    /// Whether `region` is shown.
    internal func isVisible(_ region: Region) -> Bool {
        settings.flag(region.settingsKey, default: region.isShownByDefault)
    }

    /// Shows or hides `region`.
    internal func setVisible(_ region: Region, _ visible: Bool) {
        guard visible != isVisible(region) else {
            return
        }
        settings.set(visible, forKey: region.settingsKey)
        onChange?()
    }

    /// Keeps the position the user dragged the divider to.
    ///
    /// The window already shows it, so nothing is redrawn.
    internal func rememberDivider(_ divider: Int) {
        settings.set(Self.clamped(divider), forKey: Self.dividerKey)
    }

    /// The page of the configuration dialog for these settings (spec 13 › Layout page).
    internal func preferencePage() -> PreferencePage {
        var preferences = Region.allCases.map { region in
            Preference(
                region.settingsKey,
                "Show \(region.caption.lowercased())",
                .flag(default: region.isShownByDefault)
            )
        }
        preferences.append(Preference(Self.stackedKey, "Panels one above the other", .flag(default: false)))
        preferences.append(
            Preference(
                BarButton.iconSizeKey,
                "Size of the button bar's pictures",
                .choice(BarButton.iconSizeNames, default: BarButton.defaultIconSize)
            )
        )
        preferences.append(
            Preference(Self.titleExtraKey, "Extra text in the window title (*text or $text)", .text(default: ""))
        )
        return PreferencePage(title: "Layout", preferences: preferences) { [weak self] in self?.onChange?() }
    }

    deinit {
        // Nothing to release.
    }
}
