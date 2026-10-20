import AFMKernel
import AppKit

/// The current-directory bar: the path with the display mask, coloured by whether its panel is the
/// source.
///
/// Each part of the path can be clicked to go there (spec 03 › Current-directory bar). While the
/// folder is on a drive that can be ejected, an eject button stands at the right end.
internal final class PathBarView: NSView {
    /// A part of the path that leads somewhere: its place in the text (UTF-16) and the folder.
    internal struct Segment: Equatable {
        /// Where the part is in the text, in UTF-16 units.
        internal let range: NSRange
        /// The folder a click on the part goes to.
        internal let location: URL
    }

    /// Where a segment is drawn, from the start of the text.
    internal struct Span {
        /// Its left edge.
        internal let minX: CGFloat
        /// Its right edge.
        internal let maxX: CGFloat
    }

    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let inset: CGFloat = 6
    private static let ejectWidth: CGFloat = 22

    /// A click that did not go to a part of the path, with its click count.
    internal var onClick: ((_ clickCount: Int) -> Void)?
    /// A click on a part of the path above the current folder.
    internal var onNavigate: ((URL) -> Void)?
    /// The menu of the bar.
    internal var menuProvider: (() -> NSMenu?)?
    /// A click on the eject button.
    internal var onEject: (() -> Void)?
    /// The button that ejects the drive the folder is on.
    internal let ejectButton = NSButton()
    /// The text shown: the path and the display mask.
    internal private(set) var text = ""
    /// The clickable parts of the path, in the order of the text.
    internal private(set) var segments: [Segment] = []
    /// Where each segment is drawn, from the start of the text.
    internal private(set) var spans: [Span] = []
    /// Whether the panel is the source; the bar is drawn in the selection colour then.
    internal var isActive = false {
        didSet {
            needsDisplay = true
            ejectButton.contentTintColor = isActive ? .alternateSelectedControlTextColor : .labelColor
        }
    }

    /// The name of the drive the eject button ejects; nil hides the button.
    internal var ejectableVolumeName: String? {
        didSet {
            guard ejectableVolumeName != oldValue else {
                return
            }
            ejectButton.isHidden = ejectableVolumeName == nil
            let title = ejectableVolumeName.map { "Eject “\(DisplayText.clean($0))”" }
            ejectButton.toolTip = title
            ejectButton.setAccessibilityLabel(title)
            needsLayout = true
            needsDisplay = true
        }
    }

    private var textWidth: CGFloat = 0
    /// The area that follows the mouse.
    ///
    /// Only this one is replaced: the others belong to AppKit (the tool tip's among them).
    private var mouseArea: NSTrackingArea?
    private var hovered: Int? {
        didSet {
            if hovered != oldValue {
                needsDisplay = true
            }
        }
    }

    /// Drawn from the top down.
    override internal var isFlipped: Bool { true }

    /// Where the text starts: a path that is longer than the bar shows its end.
    internal var textOrigin: CGFloat {
        min(Self.inset, textArea - Self.inset - textWidth)
    }

    /// The width the path may take: all of the bar but the eject button.
    private var textArea: CGFloat { bounds.width - (ejectButton.isHidden ? 0 : Self.ejectWidth) }

    /// An empty bar, 22 points high, with the eject button hidden.
    override internal init(frame: NSRect) {
        super.init(frame: frame)
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ejectButton.isBordered = false
        ejectButton.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")
            .flatMap { $0.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)) }
        ejectButton.imagePosition = .imageOnly
        ejectButton.refusesFirstResponder = true
        ejectButton.target = self
        ejectButton.action = #selector(ejectPressed)
        ejectButton.isHidden = true
        addSubview(ejectButton)
    }

    /// Not made from an archive.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// Splits a path into its clickable parts.
    ///
    /// The `ancestors` are the folders from the top of the tree down to the one shown, each with
    /// the way it is written; a part is what the writing of a folder adds to that of its parent.
    /// When the writings do not build on each other (a file system with a notation of its own),
    /// the path has no clickable parts.
    internal static func segments(of text: String, ancestors: [(location: URL, path: String)]) -> [Segment] {
        let units = Array(text.utf16)
        var parts: [Segment] = []
        var covered = 0
        for ancestor in ancestors {
            let length = ancestor.path.utf16.count
            guard text.hasPrefix(ancestor.path), length >= covered else {
                return []
            }
            var range = NSRange(location: covered, length: length - covered)
            // The separator in front of a name is not part of it.
            while range.length > 1, units[range.location] == 0x2F {
                range = NSRange(location: range.location + 1, length: range.length - 1)
            }
            if range.length > 0 {
                parts.append(Segment(range: range, location: ancestor.location))
            }
            covered = length
        }
        return parts
    }

    /// Shows a path. `segments` are its clickable parts, in the order of the text.
    internal func update(text: String, segments: [Segment]) {
        guard text != self.text || segments != self.segments else {
            return
        }
        self.text = text
        self.segments = segments
        let whole = NSAttributedString(string: text, attributes: [.font: Self.font])
        func width(upTo index: Int) -> CGFloat {
            ceil(whole.attributedSubstring(from: NSRange(location: 0, length: min(index, whole.length))).size().width)
        }
        spans = segments.map { Span(minX: width(upTo: $0.range.location), maxX: width(upTo: NSMaxRange($0.range))) }
        textWidth = width(upTo: whole.length)
        hovered = nil
        needsDisplay = true
    }

    /// Puts the eject button at the right end.
    override internal func layout() {
        super.layout()
        ejectButton.frame = NSRect(
            x: bounds.width - Self.ejectWidth,
            y: 0,
            width: Self.ejectWidth,
            height: bounds.height
        )
    }

    /// The path on the colour of the bar, the part under the mouse underlined.
    override internal func draw(_: NSRect) {
        (isActive ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor)
            .setFill()
        bounds.fill()
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: Self.font,
                .foregroundColor: isActive ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor
            ]
        )
        if let hovered, segments.indices.contains(hovered) {
            attributed.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: segments[hovered].range
            )
        }
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 2, y: 0, width: max(textArea - 4, 0), height: bounds.height).clip()
        attributed.draw(at: NSPoint(x: textOrigin, y: (bounds.height - attributed.size().height) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Follows the mouse over the bar, for the underline.
    override internal func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseArea {
            removeTrackingArea(mouseArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseArea = area
    }

    /// The part under the mouse is underlined.
    override internal func mouseMoved(with event: NSEvent) {
        hovered = segment(at: convert(event.locationInWindow, from: nil))
    }

    /// The mouse left: nothing is underlined.
    override internal func mouseExited(with _: NSEvent) {
        hovered = nil
    }

    /// A click on a part of the path above the current folder goes there.
    ///
    /// Everything else is an ordinary click on the bar: the panel becomes the source, and a double
    /// click edits the path.
    override internal func mouseDown(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil), count: event.clickCount)
    }

    /// A click at `point` (in the bar's coordinates), the `count`th of a series.
    internal func click(at point: NSPoint, count: Int) {
        if let index = segment(at: point), index < segments.count - 1 {
            if count == 1 {
                onNavigate?(segments[index].location)
            }
        } else {
            onClick?(count)
        }
    }

    /// The menu of the bar.
    override internal func menu(for _: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    /// The bar draws its text itself; to the accessibility interface it is a text of its own.
    override internal func isAccessibilityElement() -> Bool {
        true
    }

    /// A text.
    override internal func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }

    /// What the text is.
    override internal func accessibilityLabel() -> String? {
        "Current folder"
    }

    /// The path and the display mask, as shown.
    override internal func accessibilityValue() -> Any? {
        text
    }

    /// The segment drawn at `point`, if any.
    private func segment(at point: NSPoint) -> Int? {
        let offset = point.x - textOrigin
        return spans.firstIndex { offset >= $0.minX && offset < $0.maxX }
    }

    /// The eject button: `onEject` hears of it.
    @objc
    private func ejectPressed() {
        onEject?()
    }
}
