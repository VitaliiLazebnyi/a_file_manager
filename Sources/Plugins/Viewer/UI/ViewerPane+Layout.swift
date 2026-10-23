import AppKit

/// Laying the text out again: after a resize, a change of the font size or of the options.
extension ViewerPane {
    /// A text wrapped at the window's edge is cut anew when the width changed, once it has
    /// stopped changing (a quarter of a second without a new size, and the window's edge let
    /// go of), with the same text at the top.
    internal func pagerResized() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resizeSettled() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Lays a text wrapped at the window's edge out anew for the width it has now, unless the
    /// window is still being resized (the end of the live resize asks again).
    internal func layOutAfterResize(whileResizing: Bool) {
        guard !whileResizing, contentView === pager, pager.shownLayout != nil, pager.shownLayout != layout else {
            return
        }
        present(keeping: pager.topOffset)
    }

    /// Shows the text again after an option changed, keeping the place.
    internal func relayout() {
        guard mode.isTextual, loaded != nil else {
            return
        }
        present(keeping: pager.document != nil ? pager.topOffset : nil)
    }

    /// Num + and Num −: the font grows or shrinks by `delta` points (0 goes back to the configured size).
    internal func changeFontSize(by delta: Double) {
        fontSizeChange = delta == 0 ? 0 : min(60, max(-8, fontSizeChange + delta))
        pager.font = currentFont
        // A size that does not change the columns (a fixed width) needs no new index; one that
        // does is laid out once the size has stopped changing (each step of a zoom would start
        // an index of the whole file).
        if pager.shownLayout != layout { pagerResized() }
    }

    /// Takes over what was changed in the configuration.
    internal func applySettings() {
        pager.showsCaret = settings.caret
        pager.searchGoBack = settings.searchGoBack
        imageView?.fit = settings.imageFit
        imageView?.centered = settings.centersImages
        if loaded != nil, mode.isTextual, contentView === pager {
            pager.font = currentFont
            if pager.shownLayout != layout { relayout() }
        }
        updateChrome()
    }

    private func resizeSettled() {
        resizeWork = nil
        layOutAfterResize(whileResizing: inLiveResize || pager.inLiveResize)
    }
}
