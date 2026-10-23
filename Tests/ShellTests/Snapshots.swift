import CoreGraphics
import Foundation
import Testing

@testable import AFMShell

/// Views drawn offscreen and compared with their reference images (`Snapshot`).
@MainActor
@Suite
internal struct Snapshots {
    /// The path bar of the panel that is not the source: the path with the display mask, in the
    /// colours that do not depend on the user's accent colour.
    @Test
    internal func thePathBarOfTheTargetPanel() {
        let bar = PathBarView(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        let paths = ["/", "/Users", "/Users/me"]
        bar.update(
            text: "/Users/me/*.*",
            segments: PathBarView.segments(of: "/Users/me", ancestors: paths.map { (URL(fileURLWithPath: $0), $0) })
        )
        let mismatch = Snapshot.mismatch(of: bar, named: "path-bar-target")
        #expect(mismatch == nil, Comment(rawValue: mismatch ?? ""))
    }
}
