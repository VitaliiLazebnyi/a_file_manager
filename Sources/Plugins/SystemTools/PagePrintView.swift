import AppKit

/// Draws pages of text for the printer: one page of the list on each sheet, in a fixed-width
/// font sized so that the page's lines fit the sheet.
///
/// Main thread only, like every view.
internal final class PagePrintView: NSView {
    private let pages: [[String]]
    private let pageSize: NSSize
    private let attributes: [NSAttributedString.Key: Any]
    private let lineHeight: CGFloat

    override internal var isFlipped: Bool { true }

    /// `longestLine` is the length of the longest line, when the caller has measured it
    /// already (off the main thread, for a long list).
    ///
    /// Without it (nil) the lines are measured here, in UTF-16 units (a count that does not cut
    /// every line into characters).
    internal init(pages: [[String]], longestLine: Int?, linesPerPage: Int, printInfo: NSPrintInfo) {
        self.pages = pages
        let bounds = printInfo.imageablePageBounds
        let paper = printInfo.paperSize
        let width = min(bounds.width, paper.width - printInfo.leftMargin - printInfo.rightMargin)
        let height = min(bounds.height, paper.height - printInfo.topMargin - printInfo.bottomMargin)
        pageSize = NSSize(width: max(width, 100), height: max(height, 100))
        lineHeight = pageSize.height / CGFloat(max(linesPerPage, 1))
        // The longest line decides the width a character may have; 0.6 em is the advance of the
        // fixed-width system font.
        let longest = CGFloat(
            max(
                longestLine ?? pages.reduce(0) { longest, page in page.reduce(longest) { max($0, $1.utf16.count) } },
                1
            )
        )
        let size = max(4, min(11, lineHeight / 1.25, pageSize.width / longest / 0.6))
        attributes = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: NSColor.black
        ]
        super
            .init(
                frame: NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height * CGFloat(max(pages.count, 1)))
            )
    }

    /// Not made from an archive: always nil.
    internal required init?(coder _: NSCoder) { nil }

    override internal func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(pages.count, 1))
        return true
    }

    override internal func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }

    override internal func draw(_ dirtyRect: NSRect) {
        for (index, lines) in pages.enumerated() where rectForPage(index + 1).intersects(dirtyRect) {
            let top = CGFloat(index) * pageSize.height
            for (row, line) in lines.enumerated() {
                NSAttributedString(string: line, attributes: attributes)
                    .draw(at: NSPoint(x: 0, y: top + CGFloat(row) * lineHeight))
            }
        }
    }
}
