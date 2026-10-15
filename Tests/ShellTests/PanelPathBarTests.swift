import AppKit
import Testing

@testable import AFMShell

/// The current-directory bar by itself (spec 03 › Current-directory bar): the path cut into the
/// folders on the way, and what a click on each does.
@MainActor
@Suite
internal struct PanelPathBarTests {
    /// The URL `text` writes.
    private func url(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    /// The ancestors of a local path, written as paths.
    private func ancestors(_ paths: [String]) -> [(location: URL, path: String)] {
        paths.map { (URL(fileURLWithPath: $0), $0) }
    }

    /// The middle of segment `index` as drawn in `bar`.
    private func center(of index: Int, in bar: PathBarView) -> NSPoint {
        NSPoint(x: bar.textOrigin + (bar.spans[index].minX + bar.spans[index].maxX) / 2, y: bar.bounds.midY)
    }

    /// A mouse event of `type` at `point` of `view`'s window.
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: view.convert(point, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }

    /// A path is cut into its folders, as each adds to the writing of its parent; a notation of
    /// its own has no parts.
    @Test
    internal func thePathIsCutIntoItsFolders() throws {
        let segments = PathBarView.segments(
            of: "/Users/me/docs",
            ancestors: ancestors(["/", "/Users", "/Users/me", "/Users/me/docs"])
        )
        #expect(
            segments.map(\.range) == [
                NSRange(location: 0, length: 1), NSRange(location: 1, length: 5), NSRange(location: 7, length: 2),
                NSRange(location: 10, length: 4)
            ]
        )
        #expect(segments.map(\.location.path) == ["/", "/Users", "/Users/me", "/Users/me/docs"])
        // A file system with a notation of its own, whose writings do not build on each other.
        #expect(PathBarView.segments(of: "archive: sub", ancestors: ancestors(["/a.zip", "/a.zip/sub"])).isEmpty)
        let memory = PathBarView.segments(
            of: "mem:/A/b",
            ancestors: [
                (try url("mem:///"), "mem:/"), (try url("mem:///A"), "mem:/A"),
                (try url("mem:///A/b"), "mem:/A/b")
            ]
        )
        #expect(
            memory.map(\.range) == [
                NSRange(location: 0, length: 5), NSRange(location: 5, length: 1), NSRange(location: 7, length: 1)
            ]
        )
        // A writing that does not grow adds no part.
        #expect(PathBarView.segments(of: "/a", ancestors: ancestors(["/a", "/a"])).count == 1)
    }

    /// A click on a part above the folder shown goes there; elsewhere it is a click on the bar.
    @Test
    internal func aClickOnAPartOfThePathGoesThere() {
        let bar = PathBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 22))
        var visited: [String] = []
        var clicks: [Int] = []
        bar.onNavigate = { visited.append($0.path) }
        bar.onClick = { clicks.append($0) }
        bar.update(text: "/Users/me/*.*", segments: PathBarView.segments(of: "/Users/me", ancestors: ancestors(["/", "/Users", "/Users/me"])))
        bar.click(at: center(of: 1, in: bar), count: 1)
        #expect(visited == ["/Users"] && clicks.isEmpty)
        // The folder that is shown, and the space behind the text, are the bar itself.
        bar.click(at: center(of: 2, in: bar), count: 2)
        bar.click(at: NSPoint(x: 390, y: 10), count: 1)
        #expect(visited == ["/Users"] && clicks == [2, 1])
        // The second click of a double click on a part does not go there twice.
        bar.click(at: center(of: 0, in: bar), count: 1)
        bar.click(at: center(of: 0, in: bar), count: 2)
        #expect(visited == ["/Users", "/"])
    }

    /// The part under the mouse is underlined and the bar is drawn in the colour of the source;
    /// a long path shows its end; the eject button stands at the right end while there is a drive
    /// to eject, and a press on it is heard.
    @Test
    internal func theBarFollowsTheMouseAndShowsTheEjectButton() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [], backing: .buffered, defer: true)
        let bar = PathBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        window.contentView?.addSubview(bar)
        let long = "/" + String(repeating: "folder/", count: 10)
        let paths = ["/"] + (1...10).map { "/" + String(String(repeating: "folder/", count: $0).dropLast()) }
        bar.update(text: long + "*.*", segments: PathBarView.segments(of: String(long.dropLast()), ancestors: ancestors(paths)))
        #expect(bar.textOrigin < 0 && bar.segments.count == 11)
        bar.updateTrackingAreas()
        bar.updateTrackingAreas()
        bar.mouseMoved(with: try mouse(.leftMouseDown, at: center(of: 10, in: bar), in: bar))
        bar.isActive = true
        bar.display()
        bar.mouseExited(with: try mouse(.leftMouseDown, at: .zero, in: bar))
        var ejected = 0
        bar.onEject = { ejected += 1 }
        bar.ejectableVolumeName = "Stick"
        bar.ejectableVolumeName = "Stick"
        bar.layout()
        #expect(!bar.ejectButton.isHidden && bar.ejectButton.frame.maxX == 200 && bar.ejectButton.toolTip == "Eject “Stick”")
        bar.ejectButton.performClick(nil)
        #expect(ejected == 1)
        bar.ejectableVolumeName = nil
        #expect(bar.ejectButton.isHidden)
        // A mouse-down is a click with the event's count; the menu is the provider's.
        var clicks: [Int] = []
        bar.onClick = { clicks.append($0) }
        bar.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: 195, y: 10), in: bar))
        bar.menuProvider = { NSMenu(title: "path") }
        let menu = bar.menu(for: try mouse(.rightMouseDown, at: .zero, in: bar))
        #expect(clicks == [1] && menu?.title == "path")
    }
}
