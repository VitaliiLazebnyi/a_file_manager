import AFMKernel
import AppKit

/// The current-directory bar: the path with the display mask, coloured by whether its panel
/// is the source. Each part of the path can be clicked to go there
/// (spec 03 › Current-directory bar).
final class PathBarView: NSView {
    /// A part of the path that leads somewhere: its place in the text (UTF-16) and the folder.
    struct Segment: Equatable {
        let range: NSRange
        let location: URL
    }

    /// A click that did not go to a part of the path.
    var onClick: ((_ clickCount: Int) -> Void)?
    /// A click on a part of the path above the current folder.
    var onNavigate: ((URL) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private(set) var text = ""
    private(set) var segments: [Segment] = []
    /// Where each segment is drawn, from the start of the text.
    private var spans: [(minX: CGFloat, maxX: CGFloat)] = []
    private var textWidth: CGFloat = 0
    private var hovered: Int? {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }

    var isActive = false {
        didSet { needsDisplay = true }
    }

    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let inset: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Shows a path. `segments` are its clickable parts, in the order of the text.
    func update(text: String, segments: [Segment]) {
        guard text != self.text || segments != self.segments else { return }
        self.text = text
        self.segments = segments
        let attributes: [NSAttributedString.Key: Any] = [.font: PathBarView.font]
        let whole = text as NSString
        func width(upTo index: Int) -> CGFloat {
            ceil(whole.substring(to: min(index, whole.length)).size(withAttributes: attributes).width)
        }
        spans = segments.map { (width(upTo: $0.range.location), width(upTo: NSMaxRange($0.range))) }
        textWidth = width(upTo: whole.length)
        hovered = nil
        needsDisplay = true
    }

    /// Splits a path into its clickable parts. `ancestors` are the folders from the top of the
    /// tree down to the one shown, each with the way it is written; a part is what the writing
    /// of a folder adds to that of its parent. When the writings do not build on each other
    /// (a file system with a notation of its own), the path has no clickable parts.
    static func segments(of text: String, ancestors: [(location: URL, path: String)]) -> [Segment] {
        var segments: [Segment] = []
        var covered = 0
        for ancestor in ancestors {
            let length = ancestor.path.utf16.count
            guard text.hasPrefix(ancestor.path), length >= covered else { return [] }
            var range = NSRange(location: covered, length: length - covered)
            // The separator in front of a name is not part of it.
            while range.length > 1, (text as NSString).character(at: range.location) == 0x2F {
                range = NSRange(location: range.location + 1, length: range.length - 1)
            }
            if range.length > 0 { segments.append(Segment(range: range, location: ancestor.location)) }
            covered = length
        }
        return segments
    }

    /// A path that is longer than the bar shows its end.
    private var textOrigin: CGFloat {
        min(PathBarView.inset, bounds.width - PathBarView.inset - textWidth)
    }

    private func segment(at point: NSPoint) -> Int? {
        let x = point.x - textOrigin
        return spans.firstIndex { x >= $0.minX && x < $0.maxX }
    }

    override func draw(_ dirtyRect: NSRect) {
        (isActive ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        bounds.fill()
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: PathBarView.font, .foregroundColor: isActive ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
        ])
        if let hovered, segments.indices.contains(hovered) {
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: segments[hovered].range)
        }
        NSGraphicsContext.saveGraphicsState()
        bounds.insetBy(dx: 2, dy: 0).clip()
        attributed.draw(at: NSPoint(x: textOrigin, y: (bounds.height - attributed.size().height) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = segment(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    /// A click on a part of the path above the current folder goes there. Everything else is
    /// an ordinary click on the bar: the panel becomes the source, and a double click edits
    /// the path.
    override func mouseDown(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil), count: event.clickCount)
    }

    func click(at point: NSPoint, count: Int) {
        if let index = segment(at: point), index < segments.count - 1 {
            if count == 1 { onNavigate?(segments[index].location) }
        } else {
            onClick?(count)
        }
    }

    /// The middle of a segment, for checks.
    func center(ofSegment index: Int) -> NSPoint {
        NSPoint(x: textOrigin + (spans[index].minX + spans[index].maxX) / 2, y: bounds.midY)
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
