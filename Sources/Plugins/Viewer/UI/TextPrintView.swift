import AppKit

/// The pages of a text for printing: the rows are drawn page by page as the print operation asks
/// for them, so nothing is laid out beforehand (a text view would lay out all of it on the main
/// thread before the first page could come out).
internal final class TextPrintView: NSView {
    /// The rows that are printed, one per line.
    internal let lines: [String]
    private let font: NSFont
    private let lineHeight: CGFloat
    private let linesPerPage: Int
    private let pageSize: NSSize
    private let attributes: [NSAttributedString.Key: Any]

    /// How many pages the rows take; one for no rows.
    internal var pageCount: Int { max(1, (lines.count + linesPerPage - 1) / linesPerPage) }

    /// Pages are counted from the top.
    override internal var isFlipped: Bool { true }

    /// A view as tall as the pages of `lines` in `font` take, with `pageSize` the area of a page.
    internal init(lines: [String], font: NSFont, pageSize: NSSize) {
        self.lines = lines
        self.font = font
        self.pageSize = pageSize
        lineHeight = Self.lineHeight(of: font)
        linesPerPage = Self.linesPerPage(font: font, pageHeight: pageSize.height)
        attributes = [.font: font, .foregroundColor: NSColor.black]
        // Wider than the page when a row is: the print operation then shrinks the page to fit.
        let widest = CGFloat(min(2_000, lines.reduce(0) { max($0, $1.utf16.count) })) * font.maximumAdvancement.width
        let pages = max(1, (lines.count + linesPerPage - 1) / linesPerPage)
        super
            .init(
                frame: NSRect(
                    x: 0,
                    y: 0,
                    width: max(pageSize.width, widest),
                    height: CGFloat(pages * linesPerPage) * lineHeight
                )
            )
    }

    /// Made in code only: an archive gives none.
    internal required init?(coder _: NSCoder) { nil }

    /// The area of a page the text goes on.
    internal static func pageSize(for info: NSPrintInfo) -> NSSize {
        NSSize(
            width: max(100, info.paperSize.width - info.leftMargin - info.rightMargin),
            height: max(100, info.paperSize.height - info.topMargin - info.bottomMargin)
        )
    }

    /// The height of a printed row in `font`, in points; at least 1.
    internal static func lineHeight(of font: NSFont) -> CGFloat {
        max(1, ceil(font.ascender - font.descender + font.leading))
    }

    /// How many rows in `font` fit on a page `pageHeight` points tall; at least 1.
    internal static func linesPerPage(font: NSFont, pageHeight: CGFloat) -> Int {
        max(1, Int(pageHeight / lineHeight(of: font)))
    }

    /// The pages are numbered from 1 to `pageCount`.
    override internal func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    /// The rows of `page`, counted from 1.
    override internal func rectForPage(_ page: Int) -> NSRect {
        NSRect(
            x: 0,
            y: CGFloat((page - 1) * linesPerPage) * lineHeight,
            width: frame.width,
            height: CGFloat(linesPerPage) * lineHeight
        )
    }

    /// Draws the rows that lie in `dirtyRect`.
    override internal func draw(_ dirtyRect: NSRect) {
        guard !lines.isEmpty else {
            return
        }
        let first = max(0, Int(dirtyRect.minY / lineHeight))
        let last = min(lines.count - 1, Int(dirtyRect.maxY / lineHeight))
        guard first <= last else {
            return
        }
        for index in first...last {
            lines[index].draw(at: NSPoint(x: 0, y: CGFloat(index) * lineHeight), withAttributes: attributes)
        }
    }
}
