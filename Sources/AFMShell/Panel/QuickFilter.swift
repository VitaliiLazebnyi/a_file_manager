import AFMKernel
import AppKit

/// The quick filter of one tab (spec 03 › Quick filter): what was typed, and what it was laid
/// over. A tab has one filter (`PanelModel.filter`), which the Show menu's display filters use
/// as well; the quick filter therefore keeps the filter it found (`base`) and shows only what
/// passes both. Taking the quick filter away puts `base` back.
struct QuickFilter {
    var text: String
    /// The display filter that was on when the quick filter was opened.
    let base: PanelFilter?
    /// The folder the filter belongs to; it does not survive a change of directory.
    let directory: URL

    /// What the model's filter is called while this quick filter is on. It starts with the
    /// title of `base`, so whoever set that still recognises it.
    var title: String {
        text.isEmpty ? (base?.title ?? "") : (base.map { $0.title + "  " } ?? "") + "⏷ " + text
    }

    /// The filter for the model; nil when nothing is typed and nothing lies below.
    var combined: PanelFilter? {
        guard !text.isEmpty else { return base }
        let (matches, base) = (QuickFilter.matcher(for: text), base)
        return PanelFilter(title: title) { item in matches(item.name) && (base?.matches(item) ?? true) }
    }

    /// Whether what is typed now lets through nothing that `old` did not: both are plain ASCII
    /// text (no mask), and the new contains the old. The list then only has to be filtered again
    /// from what it shows.
    static func narrows(from old: String, to new: String) -> Bool {
        guard !old.isEmpty, old.utf8.allSatisfy({ $0 < 0x80 && $0 != 0x2A && $0 != 0x3F }),
              new.utf8.allSatisfy({ $0 < 0x80 && $0 != 0x2A && $0 != 0x3F }) else { return false }
        return new.lowercased().contains(old.lowercased())
    }

    /// How typed text is compared with a name: as a file mask when it has a `*` or `?` in it,
    /// otherwise the name has to contain it. Upper and lower case are the same.
    static func matcher(for text: String) -> (String) -> Bool {
        let pattern = text.lowercased()
        if pattern.contains("*") || pattern.contains("?") {
            return { fnmatch(pattern, $0.lowercased(), 0) == 0 }
        }
        let needle = Array(pattern.utf8)
        guard needle.allSatisfy({ $0 < 0x80 }) else { return { $0.range(of: pattern, options: .caseInsensitive) != nil } }
        // Typed text is mostly plain ASCII, as most names are: those are compared byte by byte,
        // a good deal faster than Foundation does it (every key press looks at every name).
        // A name with anything else in it is left to Foundation.
        return { name in
            let found = name.utf8.withContiguousStorageIfAvailable { haystack -> Bool? in
                guard !haystack.contains(where: { $0 >= 0x80 }) else { return nil }
                guard haystack.count >= needle.count else { return false }
                for start in 0...(haystack.count - needle.count) {
                    var index = 0
                    while index < needle.count, lowercase(haystack[start + index]) == needle[index] { index += 1 }
                    if index == needle.count { return true }
                }
                return false
            }
            if let found, let verdict = found { return verdict }
            return name.range(of: pattern, options: .caseInsensitive) != nil
        }
    }

    @inline(__always) private static func lowercase(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }
}

/// The small field at the bottom of a panel the quick filter is typed into.
final class QuickFilterBar: NSView, NSTextFieldDelegate {
    private let field = NSTextField(string: "")
    /// Called with the text after every change.
    var onChange: ((String) -> Void)?
    /// Esc: the filter and the field go away.
    var onCancel: (() -> Void)?
    /// Enter or an arrow key: back to the list, the filter stays.
    var onReturn: (() -> Void)?

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let label = NSTextField(labelWithString: "Filter:")
        label.font = .systemFont(ofSize: 11)
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        field.placeholderString = "part of a name, or a mask such as *.txt"
        field.delegate = self
        let close = NSButton(title: "✕", target: self, action: #selector(closePressed))
        close.isBordered = false
        close.font = .systemFont(ofSize: 10)
        close.refusesFirstResponder = true
        close.toolTip = "Remove the filter (Esc)"
        let stack = NSStackView(views: [label, field, close])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Puts the keyboard into the field, with the caret at the end of what is there.
    func beginEditing() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }

    /// True while the field has the keyboard.
    var isEditing: Bool { field.currentEditor() != nil }

    @objc private func closePressed() { onCancel?() }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            onReturn?()
        default:
            return false
        }
        return true
    }
}
