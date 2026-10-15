import AFMKernel
import AppKit

/// One entry of the colours by file type: the names that match the mask are drawn in the colour.
///
/// The first entry that matches decides (spec 03 › Colours by file type).
internal struct ColorRule {
    /// The colours that have a name.
    ///
    /// They follow the light and the dark appearance by themselves.
    internal static let namedColors: [(name: String, color: NSColor)] = [
        ("red", .systemRed), ("green", .systemGreen), ("blue", .systemBlue), ("orange", .systemOrange),
        ("yellow", .systemYellow), ("brown", .systemBrown), ("pink", .systemPink), ("purple", .systemPurple),
        ("teal", .systemTeal), ("indigo", .systemIndigo), ("gray", .systemGray), ("grey", .systemGray)
    ]

    /// The file masks, as written.
    internal let maskText: String
    /// The colour, as written: a name or `#RRGGBB`.
    internal let colorText: String
    /// The colour the names that match are drawn in.
    internal let color: NSColor
    private let mask: FileMask

    /// The entry `maskText = colorText`: the names matching `maskText` (file masks, as in the Show
    /// menu) are drawn in the colour `colorText` names.
    ///
    /// Nil when no colour has that name.
    internal init?(maskText: String, colorText: String) {
        self.maskText = maskText
        self.colorText = colorText
        guard let color = Self.color(named: self.colorText) else {
            return nil
        }
        self.color = color
        mask = FileMask(self.maskText)
    }

    /// A colour by name (`purple`) or as `#RRGGBB`; nil when the text is neither.
    internal static func color(named text: String) -> NSColor? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = namedColors.first(where: { $0.name == text }) {
            return named.color
        }
        guard text.hasPrefix("#"), text.count == 7, let value = UInt32(text.dropFirst(), radix: 16) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Reads the list: one entry per line (or separated by `;;`), each `masks = colour`.
    ///
    /// An entry that cannot be read is left out, and so is one whose mask starts with `-`, which is
    /// how an entry is switched off without deleting it.
    internal static func parse(_ text: String) -> [Self] {
        text.replacingOccurrences(of: ";;", with: "\n").split(separator: "\n")
            .compactMap { line in
                guard let equals = line.lastIndex(of: "=") else {
                    return nil
                }
                let mask = line[..<equals].trimmingCharacters(in: .whitespaces)
                let colorText = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                guard !mask.isEmpty, !mask.hasPrefix("-") else {
                    return nil
                }
                return Self(maskText: mask, colorText: colorText)
            }
    }

    /// The colour of a name; nil when no entry matches.
    internal static func color(for name: String, in rules: [Self]) -> NSColor? {
        rules.first { $0.matches(name) }?.color
    }

    /// Whether `name` is one this entry colours.
    internal func matches(_ name: String) -> Bool {
        mask.matches(name)
    }
}
