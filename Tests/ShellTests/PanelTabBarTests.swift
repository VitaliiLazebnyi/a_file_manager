import AppKit
import Testing

@testable import AFMShell

/// The folder-tab strip (spec 03 › Tab header appearance, 03 › Renaming and rearranging):
/// changed in place, clicked, closed and dragged.
@MainActor
@Suite
internal struct PanelTabBarTests {
    /// What the strip told, in order.
    @MainActor
    private final class Record {
        var events: [String] = []

        func attach(to bar: TabBarView) {
            bar.onSelect = { [weak self] in self?.events.append("select \($0)") }
            bar.onClose = { [weak self] in self?.events.append("close \($0)") }
            bar.onMove = { [weak self] in self?.events.append("move \($0) \($1)") }
            bar.onNewTab = { [weak self] in self?.events.append("new") }
            bar.menuProvider = { [weak self] index in
                self?.events.append("menu \(index)")
                return NSMenu()
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A strip of three tabs, 300 points wide, in a window, laid out.
    private func strip() -> (bar: TabBarView, window: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 40),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        window.contentView?.addSubview(bar)
        bar.update(titles: ["first", "second", "third"], paths: ["/a", "/b", "/c"], active: 0)
        bar.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    /// A mouse event at `position` across the window.
    private func mouse(_ type: NSEvent.EventType, at position: CGFloat, clicks: Int, in window: NSWindow) throws
        -> NSEvent
    {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: NSPoint(x: position, y: 10),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clicks,
                pressure: 1
            )
        )
    }

    /// The tab buttons, in their order.
    private func buttons(of bar: TabBarView) -> [TabButton] {
        bar.stack.arrangedSubviews.compactMap { $0 as? TabButton }
    }

    /// The tabs are changed in place while their number stays, built anew when it changes, and
    /// the strip is hidden for a single tab.
    @Test
    internal func theTabStripIsChangedInPlaceWhileTheNumberOfTabsStays() {
        let bar = TabBarView()
        bar.update(titles: ["a", "b"], paths: ["/a", "/b"], active: 0)
        let before = bar.stack.arrangedSubviews
        bar.update(titles: ["a", "c"], paths: ["/a", "/c"], active: 1)
        #expect(before.count == 2 && bar.stack.arrangedSubviews.elementsEqual(before, by: ===))
        #expect(buttons(of: bar).map(\.title) == ["a", "c"] && buttons(of: bar).map(\.state) == [.off, .on])
        #expect(buttons(of: bar).map(\.toolTip) == ["/a", "/c"])
        // Another number of tabs builds the strip anew.
        bar.update(titles: ["a", "c", "d"], paths: ["/a", "/c", "/d"], active: 1)
        #expect(buttons(of: bar).map(\.title) == ["a", "c", "d"] && !bar.isHidden)
        bar.update(titles: ["a"], paths: ["/a"], active: 0)
        #expect(bar.isHidden)
    }

    /// A dragged tab lands where the middle of a neighbour was passed.
    @Test
    internal func aDraggedTabLandsWhereItsNeighboursMiddleWasPassed() {
        let frames = (0..<4).map { NSRect(x: CGFloat($0) * 100, y: 0, width: 100, height: 20) }
        #expect(TabBarView.destination(forX: 120, dragging: 1, frames: frames) == 1)
        #expect(TabBarView.destination(forX: 260, dragging: 1, frames: frames) == 2)
        #expect(TabBarView.destination(forX: 240, dragging: 1, frames: frames) == 1)
        #expect(TabBarView.destination(forX: 900, dragging: 1, frames: frames) == 3)
        #expect(TabBarView.destination(forX: 40, dragging: 3, frames: frames) == 0)
        #expect(TabBarView.destination(forX: 160, dragging: 3, frames: frames) == 2)
        #expect(TabBarView.destination(forX: 10, dragging: 9, frames: frames) == 9)
    }

    /// A press and release shows the tab; a press that moves shows where the tab would land and
    /// moves it there when released; a press that comes back to where it started moves nothing.
    @Test
    internal func aPressShowsATabAndADragMovesIt() throws {
        let (bar, window) = strip()
        let record = Record()
        record.attach(to: bar)
        let tabs = buttons(of: bar)
        let middles = tabs.map { bar.convert($0.bounds, from: $0).midX }
        let frames = tabs.map { bar.convert($0.bounds, from: $0) }
        func event(_ type: NSEvent.EventType, _ position: CGFloat) throws -> NSEvent {
            try mouse(type, at: position, clicks: 1, in: window)
        }
        tabs[0].mouseDown(with: try event(.leftMouseDown, middles[0]))
        tabs[0].mouseUp(with: try event(.leftMouseUp, middles[0]))
        #expect(record.events == ["select 0"])
        // Dragged past the middle of the last tab: the marker shows the place, the release moves.
        tabs[0].mouseDown(with: try event(.leftMouseDown, middles[0]))
        tabs[0].mouseDragged(with: try event(.leftMouseDragged, middles[2] + 5))
        #expect(!bar.marker.isHidden && bar.marker.frame.minX == frames[2].maxX)
        tabs[0].mouseUp(with: try event(.leftMouseUp, middles[2] + 5))
        #expect(record.events == ["select 0", "move 0 2"] && bar.marker.isHidden)
        // Dragged and brought back: nothing moves.
        tabs[2].mouseDown(with: try event(.leftMouseDown, middles[2]))
        tabs[2].mouseDragged(with: try event(.leftMouseDragged, middles[0] - 10))
        #expect(!bar.marker.isHidden && bar.marker.frame.minX == frames[0].minX - 2)
        tabs[2].mouseDragged(with: try event(.leftMouseDragged, middles[2]))
        #expect(bar.marker.isHidden)
        tabs[2].mouseUp(with: try event(.leftMouseUp, middles[2]))
        // Without a press, moving and letting go do nothing.
        tabs[1].mouseDragged(with: try event(.leftMouseDragged, middles[0]))
        tabs[1].mouseUp(with: try event(.leftMouseUp, middles[0]))
        #expect(record.events == ["select 0", "move 0 2"] && bar.marker.isHidden)
    }

    /// The buttons follow the mouse themselves; a double or middle click closes a tab, a right
    /// click asks for its menu, and a double or middle click on the free space opens a new tab.
    @Test
    internal func theButtonsTakeTheClicksOfTheirTab() throws {
        let (bar, window) = strip()
        let record = Record()
        record.attach(to: bar)
        let second = buttons(of: bar)[1]
        let middle = bar.convert(second.bounds, from: second).midX
        second.mouseDown(with: try mouse(.leftMouseDown, at: middle, clicks: 1, in: window))
        second.mouseUp(with: try mouse(.leftMouseUp, at: middle, clicks: 1, in: window))
        second.mouseDown(with: try mouse(.leftMouseDown, at: middle, clicks: 2, in: window))
        second.otherMouseDown(with: try mouse(.otherMouseDown, at: middle, clicks: 1, in: window))
        #expect(second.menu(for: try mouse(.rightMouseDown, at: middle, clicks: 1, in: window)) != nil)
        bar.mouseDown(with: try mouse(.leftMouseDown, at: 390, clicks: 1, in: window))
        bar.mouseDown(with: try mouse(.leftMouseDown, at: 390, clicks: 2, in: window))
        bar.otherMouseDown(with: try mouse(.otherMouseDown, at: 390, clicks: 1, in: window))
        #expect(record.events == ["select 1", "close 1", "close 1", "menu 1", "new", "new"])
        // A button outside a strip asks for no menu.
        let loose = TabButton(title: "loose", target: nil, action: nil)
        #expect(loose.menu(for: try mouse(.rightMouseDown, at: 5, clicks: 1, in: window)) == nil)
    }
}
