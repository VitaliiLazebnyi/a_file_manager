import AFMKernel
import AppKit

@testable import ViewerPlugin

/// A pager in a window that is never put on screen, with the texts it shows and the events a
/// user would send it.
@MainActor
internal final class CoverageViewerPagerBench {
    /// Wrapped at 40 columns.
    internal static let wrapped = ViewerLayout.text(TextLayoutOptions(columns: 40, wordWrap: true))

    /// The window; close it with `close()`.
    internal let window: NSWindow
    /// The pager, the window's content.
    internal let pager: TextPagerView

    /// The height of a row.
    internal var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: pager.font)) }

    /// A pager of `width` × `height` points.
    internal init(width: CGFloat, height: CGFloat) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        pager = TextPagerView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = pager
    }

    /// Lets the main queue run what it has now, without a bench.
    internal static func settleAlone() async {
        for _ in 0..<5 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { done.resume() }
            }
        }
    }

    /// `wait(until:)` without a bench.
    internal static func waitAlone(until condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: 60)
        while !condition() {
            if Date() > deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    /// A document of `text` in `layout`.
    internal func document(_ text: String, _ layout: ViewerLayout) -> TextDocument {
        TextDocument(source: DataByteSource(Data(text.utf8)), encoding: .utf8, layout: layout)
    }

    /// Shows `document` and waits until its first rows are there.
    internal func show(_ document: TextDocument) async -> Bool {
        pager.show(document, parallel: false)
        return await wait { pager.document === document && pager.position != nil && !pager.isIndexing }
    }

    /// Waits until `condition` holds, letting the main queue run meanwhile; false after a minute.
    internal func wait(until condition: () -> Bool) async -> Bool {
        await Self.waitAlone(until: condition)
    }

    /// Lets the main queue run what it has now.
    internal func settle() async {
        await Self.settleAlone()
    }

    /// A mouse event of `type` at `column` of the row `row` places below the top, in the window.
    internal func mouse(
        _ type: NSEvent.EventType,
        row: CGFloat,
        column: CGFloat,
        clicks: Int,
        flags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        let inPager = NSPoint(x: 5 + column * pager.characterWidth, y: 5 + (row + 0.5) * lineHeight)
        return NSEvent.mouseEvent(
            with: type,
            location: pager.convert(inPager, to: nil),
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        )
    }

    /// Closes the window.
    internal func close() {
        pager.clear()
        window.close()
    }

    deinit {
        // Nothing to release.
    }
}
