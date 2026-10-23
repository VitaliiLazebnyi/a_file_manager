import AFMContracts
import AFMKernel
import Foundation

/// The sort commands of the Show menu, and the sorting of long lists in the background.
extension ViewOptionsPlugin {
    /// One sort key of the Show menu: its command and the function key that goes with Control.
    private struct SortChoice {
        let id: CommandID
        let title: String
        let functionKey: Int
        let key: SortKey
    }

    /// The sort keys, in the order of the menu.
    private static let sortChoices = [
        SortChoice(id: .sortByName, title: "Name", functionKey: 3, key: .name),
        SortChoice(id: .sortByExtension, title: "Extension", functionKey: 4, key: .ext),
        SortChoice(id: .sortByTime, title: "Time", functionKey: 5, key: .date),
        SortChoice(id: .sortBySize, title: "Size", functionKey: 6, key: .size),
        SortChoice(id: .unsorted, title: "Unsorted", functionKey: 7, key: .unsorted)
    ]

    /// Registers one command per sort key and Reversed Order.
    internal func registerSorting(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let reload = { kernel.panels.source.reload() }
        for choice in Self.sortChoices {
            let key = choice.key
            commands.register(
                Command(choice.id, choice.title, [.f(choice.functionKey, .control)]),
                checked: { model().sort.key == key },
                { [self] in
                    sort(model(), reload: reload) { _ in ListOrder(key: key, descending: key.startsDescending) }
                }
            )
        }
        commands.register(
            Command(.reversedOrder, "Reversed Order"),
            checked: { model().sort.descending },
            { [self] in
                sort(model(), reload: reload) { current in
                    ListOrder(key: current.key, descending: !current.descending)
                }
            }
        )

        kernel.menus.add(Self.sortChoices.map(\.id), to: .showSortKey)
        kernel.menus.add([.reversedOrder], to: .showSortDirection)
    }

    /// Gives a panel the order `change` makes of its present one.
    ///
    /// A short list is sorted on the spot. A long one is sorted on a background thread and handed
    /// to the panel when it is done, so the window stays alive meanwhile.
    private func sort(_ model: PanelModel, reload: () -> Void, _ change: (ListOrder) -> ListOrder) {
        let id = ObjectIdentifier(model)
        let order = change(pendingOrders[id] ?? model.wantedSort)
        // Unsorted takes the list as it is (no work, whatever the length); the order the entries
        // came in is gone from a list that was sorted, so the folder is read again.
        if order.key == .unsorted {
            pendingOrders[id] = nil
            let isAsItCame = model.isInArrivalOrder
            model.setSort(order)
            if !isAsItCame { reload() }
            return
        }
        guard model.listedItems.count >= Self.backgroundSortThreshold else {
            pendingOrders[id] = nil
            model.setSort(order)
            return
        }
        pendingOrders[id] = order
        // The wish is the model's from here on: a reading of the folder that arrives while
        // the list is being sorted brings this order with it.
        model.requestSort(order)
        sortInBackground(model, to: order)
    }

    /// Sorts a copy of the list off the main thread.
    ///
    /// The model knows the order that is wanted (`requestSort`), so a folder that changes while the
    /// copy is sorted costs nothing here: the reading that arrives is taken in that order by
    /// whoever reads it, and the result made here is then of no use. Only a change that brings no
    /// list (another filter) leaves the list in its old order; then it is sorted again, in the
    /// background as before. Nothing is ever sorted on the main thread for a long list.
    private func sortInBackground(_ model: PanelModel, to order: ListOrder) {
        let id = ObjectIdentifier(model)
        let basis = model.basis
        // Taken on the main thread: the background thread does not read the plugin.
        let toMain = onMain
        background { [self] in
            let prepared = PanelModel.prepare(basis, sort: order)
            toMain { [self] in
                // A later command has taken over.
                guard pendingOrders[id] == order else {
                    return
                }
                if model.apply(prepared) != .stale || model.sort == order {
                    // Sorted here, or brought in this order by a reading meanwhile.
                    pendingOrders[id] = nil
                    return
                }
                // The order was changed by another route meanwhile (a click on a column, a
                // restored tab): that one is the newer wish, and this result is dropped.
                guard model.requestedSort == order else {
                    pendingOrders[id] = nil
                    return
                }
                // Still wished for and not met: no reading came (it brings the wished order),
                // only a filter, so the list is as long as it was and is sorted again here.
                sortInBackground(model, to: order)
            }
        }
    }
}
