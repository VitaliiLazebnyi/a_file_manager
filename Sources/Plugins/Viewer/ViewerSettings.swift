import AFMKernel
import Foundation

/// The display modes of the Options menu, numbered as their keys (spec 10 › Mode list).
enum ViewMode: Int, CaseIterable {
    case text = 1
    case binary, hex, media, html, unicode, utf8, preview

    var title: String {
        switch self {
        case .text: return "Text only"
        case .binary: return "Binary (fixed line length)"
        case .hex: return "Hex"
        case .media: return "Image/Multimedia"
        case .html: return "HTML text (strip tags)"
        case .unicode: return "Unicode"
        case .utf8: return "UTF-8"

        // The Mac's counterpart of the Explorer preview and of Lister plugins.
        case .preview: return "Quick Look Preview"
        }
    }

    /// The modes that show rows of text in the pager.
    var isTextual: Bool { self != .media && self != .preview }
}

/// The three fonts of the Options menu (spec 10 › Font slots): each stands for a font and,
/// unless the Encoding menu says otherwise, a character set.
enum FontSlot: Int {
    case ansi, ascii, variable

    var encoding: ViewerEncoding { self == .ascii ? .dos : .ansi }
}

/// How an image is fitted to the window (the specification's `ShrinkBitmap`).
enum ImageFit: Int {
    case none, window, largerOnly
}

/// The Lister's options: those of Configure Lister (spec 10 › Configure Lister) and those the
/// viewer remembers by itself (wrap, text cursor, fonts, window size). They live in the
/// settings store under `viewer.…`. Main thread only.
final class ListerSettings {
    private let store: any SettingsStore

    init(_ store: any SettingsStore) {
        self.store = store
    }

    private enum Key {
        static let startupMode = "viewer.startupMode", startupFont = "viewer.startupFont"
        static let fixedFont = "viewer.fixedFont", variableFont = "viewer.variableFont"
        static let textWidth = "viewer.textWidth", binaryWidth = "viewer.binaryWidth", tabWidth = "viewer.tabWidth"
        static let unwrapWidth = "viewer.unwrapWidth", searchGoBack = "viewer.searchGoBack"
        static let wrap = "viewer.wrap", caret = "viewer.caret"
        static let graphics = "viewer.loadGraphics", multimedia = "viewer.multimedia", rtf = "viewer.rtf"
        static let htmlAsText = "viewer.htmlAsText", linkBraces = "viewer.linkBraces"
        static let quickLook = "viewer.quickLook", quickLookTypes = "viewer.quickLookTypes"
        static let mediaTypes = "viewer.additionalMediaTypes", noMediaTypes = "viewer.noMediaTypes"
        static let fit = "viewer.fitImages", center = "viewer.centerImages", gifDelay = "viewer.gifMinDelay"
        static let volume = "viewer.playerVolume", frame = "viewer.windowFrame", quickFrame = "viewer.quickWindowFrame"
        static let searchHistory = "viewer.searchHistory", searchOptions = "viewer.searchOptions",
            userEncodings = "viewer.userEncodings"
        static let margins = "viewer.printMargins"
    }

    static let defaultQuickLookTypes =
        "doc docx xls xlsx ppt pptx pages numbers key odt ods odp epub svg eps ai usdz stl obj dae gltf"

    private func number(_ key: String, default value: Int, in range: ClosedRange<Int>) -> Int {
        min(
            range.upperBound,
            max(
                range.lowerBound,
                Int(store.text(key, default: String(value)).trimmingCharacters(in: .whitespaces)) ?? value))
    }

    // MARK: Configure Lister

    /// 0 = auto-detect, 1 text, 2 binary, 3 hex (the mode part of the specification's `Startup`).
    var startupMode: Int { store.index(Key.startupMode, default: 0) }
    /// 0 = auto-detect, 1 ANSI, 2 ASCII, 3 variable (the font part of `Startup`).
    var startupFont: Int { store.index(Key.startupFont, default: 0) }
    /// Characters per row of wrapped text; 0 wraps at the edge of the window.
    var textWidth: Int { number(Key.textWidth, default: 0, in: 0...16_384) }
    var binaryWidth: Int { number(Key.binaryWidth, default: 75, in: 8...1_024) }
    var tabWidth: Int { number(Key.tabWidth, default: 8, in: 1...64) }
    /// Where a row is cut when text is not wrapped.
    var unwrapWidth: Int { number(Key.unwrapWidth, default: 1_024, in: 80...16_384) }
    var searchGoBack: Int { number(Key.searchGoBack, default: 3, in: 0...50) }
    var loadsGraphics: Bool { store.flag(Key.graphics, default: true) }
    var playsMultimedia: Bool { store.flag(Key.multimedia, default: true) }
    var showsRTF: Bool { store.flag(Key.rtf, default: true) }
    var showsHTMLAsText: Bool { store.flag(Key.htmlAsText, default: true) }
    var linkBraces: Bool { store.flag(Key.linkBraces, default: true) }
    var usesQuickLook: Bool { store.flag(Key.quickLook, default: true) }
    var quickLookTypes: Set<String> {
        ViewerDetection.extensions(in: store.text(Key.quickLookTypes, default: Self.defaultQuickLookTypes))
    }
    var additionalMediaTypes: Set<String> { ViewerDetection.extensions(in: store.text(Key.mediaTypes, default: "")) }
    var noMediaTypes: Set<String> { ViewerDetection.extensions(in: store.text(Key.noMediaTypes, default: "")) }
    var gifMinimumDelay: Double { Double(number(Key.gifDelay, default: 80, in: 10...5_000)) / 1_000 }

    /// The page of the configuration dialog; `onChange` runs after the user changed something.
    static func preferencePage(onChange: @escaping @MainActor @Sendable () -> Void) -> PreferencePage {
        PreferencePage(
            title: "Lister",
            preferences: [
                Preference(
                    Key.startupMode, "Display at startup",
                    .choice(["Autodetect", "Text", "Binary", "Hex"], default: 0)),
                Preference(
                    Key.startupFont, "Font at startup",
                    .choice(["Autodetect", "ANSI", "ASCII (DOS)", "Variable"], default: 0)),
                Preference(Key.fixedFont, "Fixed-width font (name, size; empty = default)", .text(default: "")),
                Preference(Key.variableFont, "Variable-width font (name, size; empty = default)", .text(default: "")),
                Preference(
                    Key.textWidth, "Display width, text (characters per line; 0 = window width)", .text(default: "0")),
                Preference(Key.binaryWidth, "Display width, binary (characters per line)", .text(default: "75")),
                Preference(Key.unwrapWidth, "Longest line when text is not wrapped", .text(default: "1024")),
                Preference(Key.tabWidth, "Tab width", .text(default: "8")),
                Preference(Key.searchGoBack, "Search result: lines from top of list", .text(default: "3")),
                Preference(Key.wrap, "Wrap text", .flag(default: true)),
                Preference(Key.caret, "Show text cursor", .flag(default: true)),
                Preference(Key.graphics, "Load images and PDF as graphics at startup", .flag(default: true)),
                Preference(Key.multimedia, "Multimedia (audio, video)", .flag(default: true)),
                Preference(Key.rtf, "RTF", .flag(default: true)),
                Preference(Key.htmlAsText, "Show HTML as text with links", .flag(default: true)),
                Preference(Key.linkBraces, "Show links in HTML with surrounding { }", .flag(default: true)),
                Preference(Key.quickLook, "Use Quick Look previews", .flag(default: true)),
                Preference(
                    Key.quickLookTypes, "File types shown with Quick Look at startup",
                    .text(default: defaultQuickLookTypes)),
                Preference(Key.mediaTypes, "Additional multimedia file types", .text(default: "")),
                Preference(Key.noMediaTypes, "File types never shown as image or multimedia", .text(default: "")),
                Preference(
                    Key.fit, "Images",
                    .choice(["Actual size", "Fit image to window", "Fit only larger images to window"], default: 0)),
                Preference(Key.center, "Center images", .flag(default: false)),
                Preference(Key.gifDelay, "Animated GIF: shortest frame delay (ms)", .text(default: "80"))
            ], onChange: onChange)
    }

    // MARK: Remembered by the viewer

    var wrap: Bool {
        get { store.flag(Key.wrap, default: true) }
        set { store.set(newValue, forKey: Key.wrap) }
    }

    var caret: Bool {
        get { store.flag(Key.caret, default: true) }
        set { store.set(newValue, forKey: Key.caret) }
    }

    var imageFit: ImageFit {
        get { ImageFit(rawValue: store.index(Key.fit, default: 0)) ?? .none }
        set { store.set(newValue.rawValue, forKey: Key.fit) }
    }

    var centersImages: Bool {
        get { store.flag(Key.center, default: false) }
        set { store.set(newValue, forKey: Key.center) }
    }

    /// 0…1.
    var playerVolume: Float {
        get { min(1, max(0, store.value(Float.self, forKey: Key.volume) ?? 1)) }
        set { store.set(min(1, max(0, newValue)), forKey: Key.volume) }
    }

    /// The font of a slot as name and size; nil names the system's default font.
    func font(_ slot: FontSlot) -> (name: String?, size: Double) {
        let text = store.text(slot == .variable ? Key.variableFont : Key.fixedFont, default: "")
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let size = parts.count > 1 ? Double(parts[1]).map { min(96, max(6, abs($0))) } : nil
        return (parts.first.flatMap { $0.isEmpty ? nil : $0 }, size ?? (slot == .variable ? 13 : 12))
    }

    func setFontSize(_ size: Double, for slot: FontSlot) {
        let name = font(slot).name ?? ""
        store.set(
            "\(name),\(Int(min(96, max(6, size)).rounded()))",
            forKey: slot == .variable ? Key.variableFont : Key.fixedFont)
    }

    /// The frame of the Lister window (`quick`: of the separate quick view) in the notation of
    /// `NSStringFromRect`; saved with Options › Save position and when a window closes.
    func windowFrame(quick: Bool) -> String? { store.value(String.self, forKey: quick ? Key.quickFrame : Key.frame) }
    func setWindowFrame(_ frame: String, quick: Bool) { store.set(frame, forKey: quick ? Key.quickFrame : Key.frame) }

    /// What was searched for, newest first; shared by every Lister window.
    var searchHistory: [String] {
        get { store.value([String].self, forKey: Key.searchHistory) ?? [] }
        set { store.set(Array(newValue.prefix(20)), forKey: Key.searchHistory) }
    }

    var searchOptions: SearchOptions {
        get { store.value(SearchOptions.self, forKey: Key.searchOptions) ?? SearchOptions() }
        set { store.set(newValue, forKey: Key.searchOptions) }
    }

    /// Code pages the user added to the Encoding menu with "Other".
    var userCodePages: [Int] {
        get { store.value([Int].self, forKey: Key.userEncodings) ?? [] }
        set { store.set(newValue, forKey: Key.userEncodings) }
    }

    /// Left, right, top and bottom print margins in points; nil until Page Setup stored some.
    var printMargins: [Double]? {
        get { store.value([Double].self, forKey: Key.margins) }
        set { store.set(newValue, forKey: Key.margins) }
    }
}
