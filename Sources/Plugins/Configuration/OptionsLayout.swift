import AppKit

/// The building blocks the pages of the Options window share.
///
/// Main thread only.
@MainActor
internal enum OptionsLayout {
    /// A list with a column of buttons to its right, the shape of the editors of spec 14, and
    /// `below` under both.
    internal static func editor(_ list: NSView, buttons: [NSView], below: [NSView]) -> NSView {
        let column = filledStack(buttons + [spacer()], vertical: true, spacing: 6)
        column.setHuggingPriority(.required, for: .horizontal)
        return filledStack(
            [filledStack([list, column], vertical: false, spacing: 10)] + below,
            vertical: true,
            spacing: 8
        )
    }

    /// A hint under an editor, in small grey text that wraps.
    internal static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }
}
