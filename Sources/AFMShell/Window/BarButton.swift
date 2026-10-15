import AFMKernel
import AppKit

/// The look the buttons of the bars share.
///
/// Flat, framed only under the mouse, drawn pressed while their state is on (spec 02 ›
/// Horizontal button bar: appearance). Main thread only.
@MainActor
internal enum BarButton {
    /// The height of a button with small pictures.
    internal static let height: CGFloat = 24
    /// Settings key of the size of the button bar's pictures: an index into `iconSizes`.
    internal static let iconSizeKey = "window.buttonBarIconSize"
    /// The names of the sizes, for the configuration dialog.
    internal static let iconSizeNames = ["Small", "Medium", "Large", "Extra large"]
    /// Point sizes of the pictures; the buttons grow with them.
    internal static let iconSizes: [CGFloat] = [13, 20, 28, 36]
    /// The size the bar starts with: Large.
    internal static let defaultIconSize = 2

    /// The point size of the pictures the user chose, within the sizes there are.
    internal static func iconSize(from settings: any SettingsStore) -> CGFloat {
        iconSizes[min(max(settings.index(iconSizeKey, default: defaultIconSize), 0), iconSizes.count - 1)]
    }

    /// A button in the look of the bars that sends `action` to `target`.
    internal static func make(target: AnyObject, action: Selector) -> NSButton {
        style(NSButton(title: "", target: target, action: action))
    }

    /// Gives `button` the look of the bars; returns it.
    internal static func style<Button: NSButton>(_ button: Button) -> Button {
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.showsBorderOnlyWhileMouseInside = true
        button.refusesFirstResponder = true
        button.font = .systemFont(ofSize: 11)
        return button
    }
}
