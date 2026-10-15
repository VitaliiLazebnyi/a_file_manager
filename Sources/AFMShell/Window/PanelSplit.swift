import AppKit

/// The two panels side by side or one above the other, and the divider between them (spec 02 ›
/// Panel divider).
///
/// Where the divider is, as a share of the window, and whether the panels are stacked is kept
/// in `WindowLayout`; only a divider the user dragged changes the stored share. Main thread only.
@MainActor
internal final class PanelSplit: NSObject, NSSplitViewDelegate {
    /// The view that holds the panels.
    internal let view = NSSplitView()
    /// Where the divider goes and whether the panels are stacked.
    private let layout: WindowLayout
    /// The left (or upper) panel, whose length is the divider's position.
    private let left: NSView
    /// True while the divider is moved by the window itself, not by the user.
    private var isPositioningDivider = false

    /// The length of the split view along its divider's axis, without the divider.
    private var extent: CGFloat {
        (view.isVertical ? view.bounds.width : view.bounds.height) - view.dividerThickness
    }

    /// The split of `left` and `right`, arranged as `layout` says once `apply` is called.
    internal init(left: NSView, right: NSView, layout: WindowLayout) {
        self.layout = layout
        self.left = left
        super.init()
        view.dividerStyle = .thin
        view.delegate = self
        view.addArrangedSubview(left)
        view.addArrangedSubview(right)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    /// Arranges the panels as `WindowLayout` says.
    internal func apply() {
        if view.isVertical == layout.isStacked {
            view.isVertical = !layout.isStacked
            view.adjustSubviews()
        }
        positionDivider()
    }

    /// Both panels keep their share of the window when it is resized.
    internal func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize _: NSSize) {
        splitView.adjustSubviews()
        positionDivider()
    }

    /// The divider stays between a tenth and nine tenths of the window.
    internal func splitView(
        _: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt _: Int
    ) -> CGFloat {
        guard extent > 0 else {
            return proposedPosition
        }
        return min(extent * 0.9, max(extent * 0.1, proposedPosition))
    }

    /// Remembers where the user dragged the divider to.
    ///
    /// The same notification follows every resizing of the window; only a drag counts.
    internal func splitViewDidResizeSubviews(_ notification: Notification) {
        let isDragging = NSApp.currentEvent?.type == .leftMouseDragged
        guard isDragging, !isPositioningDivider, notification.userInfo?["NSSplitViewDividerIndex"] != nil,
            extent > 0
        else {
            return
        }
        let length = view.isVertical ? left.frame.width : left.frame.height
        layout.rememberDivider(Int((length / extent * 1_000).rounded()))
    }

    /// Moves the divider to the share of the window `WindowLayout` keeps.
    private func positionDivider() {
        guard extent > 0 else {
            return
        }
        isPositioningDivider = true
        view.setPosition((extent * CGFloat(layout.divider) / 1_000).rounded(), ofDividerAt: 0)
        isPositioningDivider = false
    }
}
