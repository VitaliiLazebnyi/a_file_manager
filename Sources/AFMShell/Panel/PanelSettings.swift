import AFMKernel
import AppKit

/// The user's options for the file lists, as the panels use them. Read from the settings when
/// the panels are made and again after the configuration page changed something; never while
/// rows are drawn.
internal struct PanelSettings {
    /// Settings key: whether a Brief column is kept to `briefWidthLimitKey` (a Boolean).
    internal static let limitsBriefWidthKey = "panel.limitBriefWidth"
    /// Settings key: the widest Brief column in points, as text.
    internal static let briefWidthLimitKey = "panel.briefWidthLimit"
    /// Settings key: the index of the thumbnail size in `thumbnailSizes`.
    internal static let thumbnailSizeKey = "panel.thumbnailSize"
    /// Settings key: whether a drop asks before it copies or moves (a Boolean).
    internal static let confirmsDropsKey = "panel.confirmDragAndDrop"
    /// Settings key: whether names are coloured by file type (a Boolean).
    internal static let colorsByTypeKey = "panel.colorsByFileType"
    /// Settings key: the list of colours by file type, entries separated by `;;`.
    internal static let colorRulesKey = "panel.colorRules"

    /// The sides of a thumbnail tile the user can choose from, in points.
    internal static let thumbnailSizes: [CGFloat] = [64, 96, 128, 192, 256]
    /// What the colour list holds until the user writes his own.
    internal static let defaultColorRules =
        "*.zip *.tar *.gz *.tgz *.bz2 *.xz *.7z *.rar *.dmg = purple\n*.app *.command *.sh = green"

    /// The cap on the width of a Brief column in points; nil lets the longest name decide
    /// (spec 03 › Brief).
    internal var briefWidthLimit: CGFloat? = 200
    /// The side of a thumbnail tile in points (spec 03 › Thumbnails).
    internal var thumbnailSide: CGFloat = 96
    /// Whether a drop asks before it copies or moves (spec 05 › Drag & drop, Confirmation).
    internal var confirmsDrops = true
    /// The colours by file type; empty when they are switched off.
    internal var colorRules: [ColorRule] = []

    /// The options as they are before anything is read: what a new panel starts with.
    internal init() {
        // Every option as declared.
    }

    /// The options as `settings` has them; what is missing or out of range takes its default.
    internal init(from settings: any SettingsStore) {
        let limit = CGFloat(Double(settings.text(Self.briefWidthLimitKey, default: "200")) ?? 200)
        briefWidthLimit = settings.flag(Self.limitsBriefWidthKey, default: true) ? max(60, limit) : nil
        let sizes = Self.thumbnailSizes
        thumbnailSide = sizes[min(max(settings.index(Self.thumbnailSizeKey, default: 1), 0), sizes.count - 1)]
        confirmsDrops = settings.flag(Self.confirmsDropsKey, default: true)
        if settings.flag(Self.colorsByTypeKey, default: false) {
            colorRules = ColorRule.parse(settings.text(Self.colorRulesKey, default: Self.defaultColorRules))
        }
    }

    /// The configuration page of the file lists; `onChange` runs on the main thread after the
    /// user changed something on it.
    internal static func page(onChange: @escaping @MainActor @Sendable () -> Void) -> PreferencePage {
        PreferencePage(
            title: "File Panels",
            preferences: [
                Preference(limitsBriefWidthKey, "Limit the width of Brief view columns", .flag(default: true)),
                Preference(briefWidthLimitKey, "Widest Brief view column (points)", .text(default: "200")),
                Preference(
                    thumbnailSizeKey,
                    "Thumbnail size",
                    .choice(thumbnailSizes.map { "\(Int($0)) × \(Int($0))" }, default: 1)
                ),
                Preference(
                    confirmsDropsKey,
                    "Ask before copying or moving files dropped with the mouse",
                    .flag(default: true)
                ),
                Preference(colorsByTypeKey, "Colours by file type", .flag(default: false)),
                Preference(
                    colorRulesKey,
                    "Colour list, entries as “*.zip *.gz = purple”, separated by “;;”",
                    .text(default: defaultColorRules)
                )
            ],
            onChange: onChange
        )
    }
}
