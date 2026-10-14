import AFMKernel
import AppKit

/// What a panel remembers of its looks between sessions: the layout of the list, the plugin
/// columns it shows and the widths of all its columns (spec 03 › View types, 03 › Column
/// widths). Kept per panel under `left.view` and `right.view`.
struct PanelViewState: Codable, Equatable {
    /// The raw value of a `PanelViewMode`.
    var mode = PanelViewMode.full.rawValue
    /// Ids of the plugin columns, in display order.
    var extraColumns: [String] = []
    /// Width in points by column identifier (`FullViewColumns`).
    var columnWidths: [String: Double] = [:]

    static let keys = ["left.view", "right.view"]

    var viewMode: PanelViewMode { PanelViewMode(rawValue: mode) ?? .full }
}

/// The user's options for the file lists, as the panels use them. Read from the settings when
/// the panels are made and again after the configuration page changed something; never while
/// rows are drawn.
struct PanelSettings {
    static let limitsBriefWidthKey = "panel.limitBriefWidth"
    static let briefWidthLimitKey = "panel.briefWidthLimit"
    static let thumbnailSizeKey = "panel.thumbnailSize"
    static let confirmsDropsKey = "panel.confirmDragAndDrop"
    static let colorsByTypeKey = "panel.colorsByFileType"
    static let colorRulesKey = "panel.colorRules"

    static let thumbnailSizes: [CGFloat] = [64, 96, 128, 192, 256]
    /// What the colour list holds until the user writes his own.
    static let defaultColorRules = "*.zip *.tar *.gz *.tgz *.bz2 *.xz *.7z *.rar *.dmg = purple\n*.app *.command *.sh = green"

    /// The cap on the width of a Brief column in points; nil lets the longest name decide
    /// (spec 03 › Brief).
    var briefWidthLimit: CGFloat? = 200
    /// The side of a thumbnail tile in points (spec 03 › Thumbnails).
    var thumbnailSide: CGFloat = 96
    /// Whether a drop asks before it copies or moves (spec 05 › Drag & drop, Confirmation).
    var confirmsDrops = true
    /// The colours by file type; empty when they are switched off.
    var colorRules: [ColorRule] = []

    init() {}

    init(from settings: SettingsStore) {
        let limit = CGFloat(Double(settings.text(PanelSettings.briefWidthLimitKey, default: "200")) ?? 200)
        briefWidthLimit = settings.flag(PanelSettings.limitsBriefWidthKey, default: true) ? max(60, limit) : nil
        let sizes = PanelSettings.thumbnailSizes
        thumbnailSide = sizes[min(max(settings.index(PanelSettings.thumbnailSizeKey, default: 1), 0), sizes.count - 1)]
        confirmsDrops = settings.flag(PanelSettings.confirmsDropsKey, default: true)
        if settings.flag(PanelSettings.colorsByTypeKey, default: false) {
            colorRules = ColorRule.parse(settings.text(PanelSettings.colorRulesKey, default: PanelSettings.defaultColorRules))
        }
    }

    /// The configuration page of the file lists.
    static func page(onChange: @escaping () -> Void) -> PreferencePage {
        PreferencePage(title: "File Panels", preferences: [
            Preference(limitsBriefWidthKey, "Limit the width of Brief view columns", .flag(default: true)),
            Preference(briefWidthLimitKey, "Widest Brief view column (points)", .text(default: "200")),
            Preference(thumbnailSizeKey, "Thumbnail size", .choice(thumbnailSizes.map { "\(Int($0)) × \(Int($0))" }, default: 1)),
            Preference(confirmsDropsKey, "Ask before copying or moving files dropped with the mouse", .flag(default: true)),
            Preference(colorsByTypeKey, "Colours by file type", .flag(default: false)),
            Preference(colorRulesKey, "Colour list, entries as “*.zip *.gz = purple”, separated by “;;”", .text(default: defaultColorRules)),
        ], onChange: onChange)
    }
}

/// One entry of the colours by file type: the names that match the mask are drawn in the
/// colour. The first entry that matches decides (spec 03 › Colours by file type).
struct ColorRule {
    let maskText: String
    let colorText: String
    let color: NSColor
    private let mask: FileMask

    init(maskText: String, colorText: String, color: NSColor) {
        self.maskText = maskText
        self.colorText = colorText
        self.color = color
        mask = FileMask(maskText)
    }

    func matches(_ name: String) -> Bool { mask.matches(name) }

    /// The colours that have a name. They follow the light and the dark appearance by themselves.
    static let namedColors: [(name: String, color: NSColor)] = [
        ("red", .systemRed), ("green", .systemGreen), ("blue", .systemBlue), ("orange", .systemOrange), ("yellow", .systemYellow),
        ("brown", .systemBrown), ("pink", .systemPink), ("purple", .systemPurple), ("teal", .systemTeal), ("indigo", .systemIndigo),
        ("gray", .systemGray), ("grey", .systemGray),
    ]

    /// A colour by name (`purple`) or as `#RRGGBB`; nil when the text is neither.
    static func color(named text: String) -> NSColor? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = namedColors.first(where: { $0.name == text }) { return named.color }
        guard text.hasPrefix("#"), text.count == 7, let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }

    /// Reads the list: one entry per line (or separated by `;;`), each `masks = colour`. An
    /// entry that cannot be read is left out, and so is one whose mask starts with `-`, which
    /// is how an entry is switched off without deleting it.
    static func parse(_ text: String) -> [ColorRule] {
        text.replacingOccurrences(of: ";;", with: "\n").split(separator: "\n").compactMap { line in
            guard let equals = line.lastIndex(of: "=") else { return nil }
            let mask = line[..<equals].trimmingCharacters(in: .whitespaces)
            let colorText = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !mask.isEmpty, !mask.hasPrefix("-"), let color = color(named: colorText) else { return nil }
            return ColorRule(maskText: mask, colorText: colorText, color: color)
        }
    }

    /// The colour of a name; nil when no entry matches.
    static func color(for name: String, in rules: [ColorRule]) -> NSColor? {
        rules.first { $0.matches(name) }?.color
    }
}
