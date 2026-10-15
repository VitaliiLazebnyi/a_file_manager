import AFMContracts
import AFMKernel
import AppKit

/// The quick filter (spec 03 › Quick filter): a field at the bottom of the panel whose text
/// filters the list as it is typed, over the display filter, for one folder of one tab.
extension PanelViewController {
    /// How long typing in the field waits for the next key before the list is filtered: the list
    /// is filtered once for a burst of keys, not once per key.
    internal static let quickFilterDelay: TimeInterval = 0.1

    /// The text of the active tab's quick filter; nil when it has none.
    internal var quickFilterText: String? { quickFilters[ObjectIdentifier(model)]?.text }

    /// Opens the filter field of the active tab and puts the keyboard into it.
    ///
    /// A filter that is already on is shown, ready to be changed.
    internal func showQuickFilter() {
        let id = ObjectIdentifier(model)
        if quickFilters[id] == nil {
            quickFilters[id] = QuickFilter(text: "", base: model.filter, directory: model.directory)
        }
        showQuickFilterBar()
        quickFilterBar.beginEditing()
    }

    /// Shows the field when the active tab has a quick filter, with its text.
    internal func showQuickFilterBar() {
        let filter = quickFilters[ObjectIdentifier(model)]
        // A field that goes away while it has the keyboard hands it back to the list.
        if filter == nil, quickFilterBar.isEditing {
            view.window?.makeFirstResponder(listView)
        }
        quickFilterBar.isHidden = filter == nil
        // The text in the field is ahead of the filter while typing waits for the list.
        if let filter, pendingQuickFilter == nil, quickFilterBar.text != filter.text {
            quickFilterBar.text = filter.text
        }
    }

    /// Something was typed into the field: the list follows in a moment.
    internal func quickFilterEdited(_ text: String) {
        pendingQuickFilter?()
        let tab = model
        pendingQuickFilterTyping = (tab, text)
        pendingQuickFilter = MainLoop.after(Self.quickFilterDelay) { [weak self] in
            guard let self else {
                return
            }
            pendingQuickFilter = nil
            pendingQuickFilterTyping = nil
            applyQuickFilter(text, to: tab)
        }
    }

    /// Applies the text typed a moment ago to the tab it was typed in, which is no longer the active one.
    internal func flushPendingQuickFilter() {
        guard let typing = pendingQuickFilterTyping else {
            return
        }
        dropPendingQuickFilter()
        applyQuickFilter(typing.text, to: typing.tab)
    }

    /// Forgets the text that waits for the list.
    internal func dropPendingQuickFilter() {
        pendingQuickFilter?()
        pendingQuickFilter = nil
        pendingQuickFilterTyping = nil
    }

    /// Gives `tab` this filter.
    ///
    /// A long list is filtered in the background, on all cores, from the list as it is
    /// (`PanelModel.prepare`), and the result taken over when that is done (`apply`), if no newer
    /// filtering of the tab has started since; a short one at once. Should the list have changed
    /// meanwhile (more of the folder arrived, it was read again, it was put in another order), the
    /// model takes nothing and the filtering starts again from the list as it is now, again in the
    /// background: never a pass over the whole list on the main thread. `narrowing`: the filter
    /// lets through nothing the one before did not. Returns true when it was done at once.
    @discardableResult
    internal func setFilter(_ filter: PanelFilter?, of tab: PanelModel, narrowing: Bool) -> Bool {
        let id = ObjectIdentifier(tab)
        filterJobs[id] = nil
        guard tab.listedItems.count >= Self.backgroundSortThreshold else {
            tab.setFilter(filter, narrowing: narrowing)
            return true
        }
        filterJobCount += 1
        let job = filterJobCount
        filterJobs[id] = job
        let change = PanelListChange(
            of: tab,
            count: 0,
            while: { [weak self] in self?.filterJobs[id] == job },
            by: { PanelModel.prepare($0, filter: filter) }
        )
        apply(change) { [weak self] outcome in
            guard let self, outcome != nil, filterJobs[id] == job else {
                return
            }
            filterJobs[id] = nil
            // Whoever waited for the filter to be in place (the quick filter's field) looks again.
            if tab === model {
                _ = dropStaleQuickFilter(of: tab)
                showQuickFilterBar()
                updateStatus()
            }
        }
        return false
    }

    /// Filters the list by this text.
    internal func quickFilterTyped(_ text: String) {
        dropPendingQuickFilter()
        applyQuickFilter(text, to: model)
    }

    /// Enter or an arrow key in the field: back to the list.
    ///
    /// The filter stays on, and so does the field as long as it holds one.
    internal func leaveQuickFilterField() {
        flushQuickFilter()
        let id = ObjectIdentifier(model)
        if quickFilters[id]?.text.isEmpty == true {
            quickFilters[id] = nil
        }
        showQuickFilterBar()
        view.window?.makeFirstResponder(listView)
        updateStatus()
    }

    /// Esc: the filter and the field go away, and the list shows again what the display
    /// filter lets through.
    internal func removeQuickFilter() {
        dropPendingQuickFilter()
        let tab = model
        filterJobs[ObjectIdentifier(tab)] = nil
        if let filter = quickFilters.removeValue(forKey: ObjectIdentifier(tab)), !filter.text.isEmpty {
            setFilter(filter.base, of: tab, narrowing: false)
        }
        showQuickFilterBar()
        updateStatus()
    }

    /// Takes the quick filter of a tab away before the tab shows another folder
    /// (the filter belongs to one folder).
    internal func dropQuickFilter(of tab: PanelModel, unlessIn directory: URL) {
        let id = ObjectIdentifier(tab)
        guard let filter = quickFilters[id], !filter.directory.isSameLocation(as: directory) else {
            return
        }
        quickFilters[id] = nil
        let pending = filterJobs[id] != nil
        filterJobs[id] = nil
        if !filter.text.isEmpty, pending || tab.filter?.title == filter.title {
            setFilter(filter.base, of: tab, narrowing: false)
        }
    }

    /// Notices that a tab's quick filter is no longer what its model filters by: the folder was
    /// changed behind the panel's back, or a display filter was chosen, which replaces it (All
    /// Files removes a quick filter, spec 03 › Show files of type).
    ///
    /// Returns true when this changed the model, which then reports another change.
    internal func dropStaleQuickFilter(of tab: PanelModel) -> Bool {
        let id = ObjectIdentifier(tab)
        guard let filter = quickFilters[id] else {
            return false
        }
        if !filter.directory.isSameLocation(as: tab.directory) {
            quickFilters[id] = nil
            // A filtering of the quick text that is still under way counts as in effect.
            let pending = filterJobs[id] != nil
            guard !filter.text.isEmpty, pending || tab.filter?.title == filter.title else {
                return false
            }
            return setFilter(filter.base, of: tab, narrowing: false)
        }
        // A filtering under way will bring the filter the quick text stands for.
        if filterJobs[id] != nil {
            return false
        }
        if !filter.text.isEmpty, tab.filter?.title != filter.title {
            quickFilters[id] = nil
        } else if filter.text.isEmpty, tab.filter?.title != filter.base?.title {
            // Nothing typed yet, and the display filter below was changed: that one is the base now.
            quickFilters[id] = QuickFilter(text: "", base: tab.filter, directory: filter.directory)
        }
        return false
    }

    /// Filters the list now, with what is in the field, if keys are still waiting.
    private func flushQuickFilter() {
        guard let cancel = pendingQuickFilter else {
            return
        }
        cancel()
        pendingQuickFilter = nil
        pendingQuickFilterTyping = nil
        quickFilterTyped(quickFilterBar.text)
    }

    /// Gives `tab` its quick filter with `text`.
    private func applyQuickFilter(_ text: String, to tab: PanelModel) {
        let id = ObjectIdentifier(tab)
        guard var filter = quickFilters[id], filter.text != text else {
            return
        }
        // Typing on narrows the list that the filter has left; anything else starts from all of it.
        let narrows = tab.filter?.title == filter.title && QuickFilter.narrows(from: filter.text, to: text)
        filter.text = text
        quickFilters[id] = filter
        setFilter(filter.combined, of: tab, narrowing: narrows)
    }
}
