import FuzzCore

@testable import AFMKernel

/// The operations that hand the model a list or change its filter.
extension PanelSession {
    /// Operation 0: a new listing, maybe of another folder.
    internal func show() {
        let items = nextItems(&choices, max: 48, besides: [])
        last = ExpectedListing(items)
        ordered = true
        model.show(
            listing(items, other: choices.int(5) == 0),
            focus: choices.bool() ? pickName() : nil,
            complete: choices.bool()
        )
    }

    /// Operation 1: a listing shown with the selection and cursor the folder had.
    internal func showRemembered() {
        let items = nextItems(&choices, max: 48, besides: [])
        last = ExpectedListing(items)
        ordered = true
        model.showRemembered(listing(items, other: false), focus: choices.bool() ? pickName() : nil)
    }

    /// Operation 2: more items for the list, sorted in its order or another; false when nothing is listed.
    internal func extend() -> Bool {
        guard model.isListed else {
            return false
        }
        let more = model.listedItems + nextItems(&choices, max: 12, besides: model.listedItems)
        let order = choices.bool() ? model.sort : nextOrder(&choices)
        last = ExpectedListing(more)
        model.extend(to: Sorter.sort(more, by: order), sortedBy: order)
        if choices.bool() {
            model.finishLoading()
        }
        return true
    }

    /// Operations 3 and 4: the list with some items gone and some new; false when nothing is listed.
    internal func update(presorted: Bool) -> Bool {
        guard model.isListed else {
            return false
        }
        var items = model.listedItems
        for _ in 0..<choices.int(4) where !items.isEmpty {
            items.remove(at: choices.int(items.count))
        }
        items += nextItems(&choices, max: 6, besides: items)
        if choices.bool() {
            items.shuffle(using: &FuzzState.shuffler)
        }
        last = ExpectedListing(items)
        ordered = true
        _ = model.update(
            with: listing(presorted ? Sorter.sort(items, by: model.sort) : items, other: false),
            focus: choices.bool() ? pickName() : nil,
            presorted: presorted ? model.sort : nil
        )
        return true
    }

    /// Operation 7: a mask filter, or none; returns the mask.
    internal func setMaskFilter() -> String {
        let masks = ["*.txt", "*", "a*", "*é*", "*.", "", "[a-c]*", "*e\u{301}*", "?", "*.TXT;*.png"]
        let mask = masks[choices.int(masks.count)]
        model.setFilter(
            choices.int(4) == 0 ? nil : PanelFilter.mask(mask),
            narrowing: choices.bool() && model.filter == nil
        )
        return mask
    }

    /// Operation 8: a size filter, or none, filtered ahead for the current or a stale list version.
    internal func setSizeFilter() {
        let filter: PanelFilter? = choices.int(4) == 0 ? nil : PanelFilter(title: "size") { $0.size > 1 }
        let stale = choices.int(4) == 0
        _ = model.setFilter(
            filter,
            prefiltered: stale ? [] : PanelModel.filtered(model.listedItems, by: filter),
            listVersion: model.listVersion - (stale ? 1 : 0)
        )
    }
}
