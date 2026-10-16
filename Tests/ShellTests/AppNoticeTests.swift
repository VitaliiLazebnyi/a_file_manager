import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Short messages near the bottom of a window that go away by themselves.
@MainActor
@Suite(.serialized)
internal struct AppNoticeTests {
    /// Makes sure AppKit is there for the panels.
    internal init() {
        _ = NSApplication.shared
    }

    /// A message over a window is a child of it that clicks go through; a newer one replaces
    /// it; the last one fades and goes by itself.
    @Test
    internal func aNoticeIsReplacedByANewerOneAndGoesByItself() async {
        // Nothing is left open. (`shown` is not asked: a window that was never on screen reports
        // itself unoccluded when it is ordered out, or here when the test says it became key.)
        let windows = StabilityWindows()
        defer {
            #expect(windows.open.isEmpty, "\(windows.openTitles)")
            windows.closeAll()
        }
        // Over a window that is never shown, and alone without coming on the screen.
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        var alone: [NSPanel] = []
        let orderInAlone = Notice.orderInAlone
        Notice.orderInAlone = { alone.append($0) }
        defer {
            Notice.orderInAlone = orderInAlone
        }
        Notice.show("Copied 3 files.", over: window)
        let first = Notice.shown
        #expect(first?.parent === window && first?.ignoresMouseEvents == true)
        #expect(first?.accessibilityLabel() == "Copied 3 files." && window.childWindows?.count == 1)
        // Centred near the bottom of the window.
        #expect(
            first.map { abs($0.frame.midX - window.frame.midX) < 1 && $0.frame.minY == window.frame.minY + 70 } == true
        )
        Notice.show("Moved.", over: nil)
        let second = Notice.shown
        #expect(second !== first && second?.parent == nil && second?.accessibilityLabel() == "Moved.")
        #expect(alone.count == 1 && alone.first === second)
        #expect(window.childWindows?.isEmpty != false && first?.isVisible == false)
        #expect(await AppWait.until { Notice.shown == nil })
        #expect(second?.isVisible == false)
    }
}
