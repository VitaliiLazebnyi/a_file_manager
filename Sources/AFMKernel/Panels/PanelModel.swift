public import Foundation

/// State of one folder tab: location, list, cursor, selection, sort order and history
/// (spec 01 › Panel state, 03 › Selection, 03 › Navigation).
///
/// The model never touches a file system. Directories are read in the background
/// (`PanelLoader`) and handed to it as a `Listing`; everything else is a change of state in
/// memory. It belongs to the main thread, and it announces every change through `onChange`,
/// so whoever shows it redraws without being told by the caller.
///
/// **Long lists.** Whatever takes time in proportion to the list (sorting, filtering, taking
/// a fresh reading, finding what a mask selects) can be worked out on a background thread
/// and applied here in one short step: `basis` is what the work starts from, the `prepare`
/// functions do it on any thread, and `apply` takes the result if the model is still as it
/// was, or says that it is not, so that the caller starts again in the background. The calls
/// that do everything at once (`setSort`, `setFilter`, `update`) are the same work done on
/// the calling thread, on all cores: right for lists of ordinary length.
///
/// Which call to use for a long list (tens of thousands of entries and more), where the
/// plain one costs the main thread time in proportion to the list:
///
/// | Plain call (main thread) | For a long list |
/// | --- | --- |
/// | `setSort(_:)`, `setSort(_:presorted:)` | `prepare(_:sort:)` + `apply` |
/// | `setFilter(_:narrowing:)`, `setFilter(_:prefiltered:listVersion:)` | `prepare(_:filter:)` + `apply` |
/// | `update(with:focus:presorted:)` | `prepare(_:update:focus:presorted:)` + `apply` |
/// | `extend(to:sortedBy:)` | `prepare(_:extendingTo:sortedBy:)` + `apply` |
/// | `setComputedSizes` on a list somebody else holds | `prepare(_:computedSizes:)` + `apply` |
/// | `select(mask:)`, `select(where:)` | `rows(of:where:)` + `setSelection(_:_:)` |
/// | `setSelected(_:names:)`, `setSelection(names:)`, `deselect(_:)` | the same, or `setSelected(_:indices:shownVersion:)` |
/// | `operands()` | `operandsSnapshot()`, then `items()` on any thread |
/// | `selection`, `savedSelection` | `hasSelection`, `selectionCount`, `isSelected`, `operandsSnapshot()` |
///
/// `selectAll`, `invertSelection`, `clearSelection`, `saveSelection`, `totals` after those,
/// `hasOperandFile`, `snapshot`, `open`, `basis` and `apply` cost next to nothing at any length.
@MainActor
public final class PanelModel {
    public nonisolated static let historyLimit = 50
    /// Lists longer than this get their index of names made along with background work.
    nonisolated static let indexedAbove = 20_000

    public enum Change: Sendable {
        /// The directory, its items or their order.
        case contents
        /// The marked items or a calculated folder size.
        case selection
        /// The cursor was moved by a command.
        case cursor
    }

    /// What a new listing does to the visited-directories history.
    public enum HistoryEffect: Sendable {
        /// A new place: recorded after the current position, dropping what lay ahead.
        case record
        /// Go Back / Go Forward: the position moves, the list stays.
        case step(Int)
        /// A reload or correction: nothing changes.
        case keep
    }

    public struct Totals: Equatable, Sendable {
        public var selectedBytes: Int64 = 0, totalBytes: Int64 = 0
        public var selectedFiles = 0, totalFiles = 0
        public var selectedFolders = 0, totalFolders = 0

        public init(
            selectedBytes: Int64 = 0, totalBytes: Int64 = 0, selectedFiles: Int = 0, totalFiles: Int = 0,
            selectedFolders: Int = 0, totalFolders: Int = 0
        ) {
            self.selectedBytes = selectedBytes
            self.totalBytes = totalBytes
            self.selectedFiles = selectedFiles
            self.totalFiles = totalFiles
            self.selectedFolders = selectedFolders
            self.totalFolders = totalFolders
        }

        /// The totals with some bytes more or less; nil when the sum leaves the range of a
        /// number or may have left it before.
        fileprivate func adding(bytes: Int64, selected: Bool) -> Self? {
            var totals = self
            let old = selected ? selectedBytes : totalBytes
            let (sum, overflow) = old.addingReportingOverflow(bytes)
            guard !overflow, old != .max, old != .min else { return nil }
            if selected { totals.selectedBytes = sum } else { totals.totalBytes = sum }
            return totals
        }
    }

    /// Called on the main thread after every change.
    public var onChange: ((Change) -> Void)?

    public private(set) var directory: URL
    /// False until the directory was read for the first time; the list is empty until then.
    public private(set) var isListed = false
    /// False while a directory is still arriving piece by piece: `items` then holds only what
    /// has come so far, and commands that mean "everything" should wait.
    public private(set) var isComplete = true
    /// True while the list is an earlier reading of the directory, shown from memory, and a
    /// fresh one is under way (`showRemembered`). `isComplete` is false for that time as well,
    /// because the list is not known to be all there is: everything that waits for a directory
    /// to arrive waits for the fresh reading in the same way, without knowing about this.
    public private(set) var isRefreshing = false
    /// The items on screen in display order, without the `[..]` row: the directory's entries
    /// that pass the display filter.
    public private(set) var items: [FileItem] = []
    /// Every entry of the directory in display order, shown or not.
    public private(set) var listedItems: [FileItem] = []
    /// What is left out of the list (spec 03 › Display filters, 03 › Quick filter); nil shows
    /// everything.
    public private(set) var filter: PanelFilter?
    /// A name the user gave the tab; nil shows the folder's name (spec 03 › Folder tabs).
    public var customTitle: String? { didSet { changed(.contents) } }
    /// A locked tab cannot be closed.
    public var isLocked = false { didSet { changed(.contents) } }
    /// Row of the cursor; row 0 is `[..]` when there is a parent row. Setting it directly is
    /// for the view that owns the cursor; commands use `moveCursor(to:)`.
    public var cursor = 0
    /// Names of the selected (marked) items. `[..]` can never be selected.
    ///
    /// The marks themselves belong to the entries, one by one (a mark is a place in the
    /// list), while two `String`s are equal as soon as they read the same: `é` in one
    /// character and `e` with an accent after it are one member of this set, though a volume
    /// that is not the Mac's own may hold a file of each name, and a list gathered from
    /// several folders may hold the same name twice. So this set is for asking about names
    /// that are known to be single; whether one particular entry is marked is asked with
    /// `isSelected(_:)` or `isSelected(row:)`, whether anything is with `hasSelection`, how
    /// many are with `selectionCount`, and the names as they are written are `selectedNames`.
    /// Made from the marks when asked for (one pass over the marked entries) and kept until
    /// they change. **Not for the main thread on long lists**: with a million marks the set
    /// takes a tenth of a second to make; none of the questions named above needs it.
    public var selection: Set<String> {
        if let names = selectionNames { return names }
        var names = Set<String>(minimumCapacity: marks.count)
        marks.forEach { names.insert(listedItems[$0].name) }
        selectionNames = names
        return names
    }

    /// The names of the marked items as they are written, in the order of the list: one for
    /// every marked entry, also where two names read the same or are the same.
    public var selectedNames: [String] {
        var names: [String] = []
        names.reserveCapacity(marks.count)
        marks.forEach { names.append(listedItems[$0].name) }
        return names
    }

    /// The names Save Selection kept. Made anew at every call, one pass over the saved
    /// marks: **not for the main thread on long lists**.
    public var savedSelection: Set<String> {
        switch saved {
        case .none: return []

        case .places(let places):
            var names = Set<String>(minimumCapacity: places.count)
            places.forEach { names.insert(listedItems[$0].name) }
            return names

        case .names(let names): return Set(names.lazy.map(\.name))

        case .remains(let remains, let places):
            var names = Set<String>(minimumCapacity: places.count)
            places.forEach { names.insert(remains.lists[0][$0].name) }
            return names
        }
    }

    /// The number of marked items; unlike `selection.count`, right for names that read the same.
    public var selectionCount: Int { marks.count }
    /// Whether anything is marked. Costs nothing, unlike `selection.isEmpty` after a change.
    public var hasSelection: Bool { !marks.isEmpty }

    /// The marked entries, by their places in `listedItems`: always as long as that list, and
    /// never holding an entry that is not shown.
    private var marks = Bitset() { didSet { (selectionNames, markedFile) = (nil, nil) } }
    private var selectionNames: Set<String>?
    /// Whether a file is among the marked entries; nil until asked, and after every change
    /// of the marks (the list cannot change without them being set).
    private var markedFile: Bool?

    /// What Save Selection kept: places of the present list for as long as it is shown, and
    /// names once the panel has left it (the marks are put back by name in another folder).
    private enum SavedMarks {
        case none
        case places(Bitset)
        case names(Set<ExactName>)
        /// A long saved selection of a list the panel has left: the names are in the list.
        case remains(Remains, Bitset)
    }

    private var saved = SavedMarks.none
    /// For each shown row the place of its item in `listedItems`, rising; nil while every
    /// entry is shown, and `items` is then the very list `listedItems` is.
    private var shownPlaces: [UInt32]?
    /// The places whose entries have a calculated size; nil until somebody needs to know.
    private var sized: Bitset?
    public private(set) var sort: ListOrder
    /// Whether the files of the list still lie in the order the file system gave them in.
    /// True for a list that was only ever shown unsorted; false from the moment it is put
    /// into the order of another key, and true again when a reading arrives while the order
    /// is `unsorted`. Sorting cannot bring that order back (`Sorter.resort`): whoever
    /// switches to `unsorted` and finds this false reads the directory again.
    public private(set) var isInArrivalOrder = true
    /// The order the user asked for, which the list is not in yet; nil once it is. See `requestSort`.
    public private(set) var requestedSort: ListOrder?
    /// The order an arriving list should be in: the requested one, else the present one.
    /// Whoever sorts a listing in the background before handing it over sorts by this.
    public var wantedSort: ListOrder { requestedSort ?? sort }
    public private(set) var showHidden: Bool
    public private(set) var volume: VolumeInfo?
    /// Counts the changes of the list (`listedItems`): of its entries or of their order.
    /// Nothing else moves it: not a refresh that found the directory as it was, not a
    /// calculated folder size, not a filter. Whoever works on a copy of the list in the
    /// background notes the number first and hands the result over only if it is still the same.
    public private(set) var listVersion = 0
    /// Counts everything a prepared change depends on: the list, the filter and the order.
    private var stamp = 0
    /// Counts the calculated sizes that were set.
    private var sizeStamp = 0

    /// Finds every listed name as it is written; made when names are looked up again and
    /// again, or along with background work, and dropped when the list changes.
    private var nameIndex: NameIndex?
    private var lookups = 0
    /// The shown rows of the names that hold more than ASCII, for a name that is written
    /// differently from every entry; made when such names keep being asked for.
    private var alikeIndex: [String: Int]?
    private var alikeLookups = 0
    /// The halves of `totals`, kept until the list or the selection changes.
    private var listTotals: Totals?
    /// Whether the shown entries' sizes add up the same in any order (`Tally.isPlain`).
    private var listTotalsArePlain = false
    private var selectedTotals: Totals?

    /// The item the cursor should go to once it arrives, while the directory is still loading.
    private var pendingFocus: String?
    private var parent: URL?
    private var root: URL
    private var history: [URL]
    private var historyIndex = 0

    public init(directory: URL, sort: ListOrder = ListOrder(), showHidden: Bool = false) {
        self.directory = directory.standardized
        self.sort = sort
        self.showHidden = showHidden
        root = self.directory
        history = [self.directory]
    }

    deinit {
        // A tab that is closed lets go of a long list in the background.
        Discard.later(&items)
        Discard.later(&listedItems)
    }

    /// A second view of the same directory, as a new tab starts (spec 03 › Opening tabs). It
    /// shows what this one shows, and like this one it says whether that is all there is: a
    /// copy made while the directory is still arriving is not complete either, until whoever
    /// shows it reads the directory for it.
    public func duplicate() -> PanelModel {
        let copy = PanelModel(directory: directory, sort: sort, showHidden: showHidden)
        (copy.items, copy.listedItems, copy.shownPlaces, copy.filter, copy.cursor) = (
            items, listedItems, shownPlaces, filter, cursor
        )
        (copy.isListed, copy.isComplete, copy.isRefreshing) = (isListed, isComplete, isRefreshing)
        (copy.marks, copy.nameIndex) = (Bitset(size: listedItems.count), nameIndex)
        (copy.parent, copy.root, copy.volume, copy.isInArrivalOrder) = (parent, root, volume, isInArrivalOrder)
        return copy
    }

    private func changed(_ change: Change) {
        MainThread.assert("A panel model")
        onChange?(change)
    }

    // MARK: Rows

    public var hasParentRow: Bool { parent != nil }
    public var rowCount: Int { items.count + (hasParentRow ? 1 : 0) }
    private var offset: Int { hasParentRow ? 1 : 0 }

    /// The item of a row; `nil` for `[..]` and for rows outside the list.
    public func item(atRow row: Int) -> FileItem? {
        let index = row - offset
        return items.indices.contains(index) ? items[index] : nil
    }

    /// The row of the item with this name. Of several items whose names read the same, the
    /// one written exactly like `name`; a name written differently from every item finds one
    /// that reads the same.
    public func row(ofName name: String) -> Int? {
        index(ofName: name).map { $0 + offset }
    }

    /// The place in `listedItems` of the entry shown at an index of `items`.
    private func place(ofShown index: Int) -> Int {
        shownPlaces.map { Int($0[index]) } ?? index
    }

    /// Where in `items` the entry at a place of `listedItems` is shown; nil when it is not.
    private func shownIndex(ofPlace place: Int) -> Int? {
        guard let places = shownPlaces else { return place < listedItems.count ? place : nil }
        var (low, high) = (0, places.count)
        while low < high {
            let middle = (low + high) / 2
            if Int(places[middle]) < place { low = middle + 1 } else { high = middle }
        }
        return low < places.count && Int(places[low]) == place ? low : nil
    }

    /// The shown entries as a set of places.
    private func shownBits() -> Bitset {
        guard let places = shownPlaces else { return Bitset.full(listedItems.count) }
        var bits = Bitset(size: listedItems.count)
        for place in places { bits.insert(Int(place)) }
        return bits
    }

    /// Every place of `listedItems` whose entry is written exactly like `name`, rising. A
    /// single question walks the list; a caller that keeps asking gets an index of all names.
    private func places(ofExactly name: String) -> [Int] {
        if nameIndex == nil {
            lookups += 1
            if lookups > 2, listedItems.count > 64 { nameIndex = NameIndex(listedItems) }
        }
        if let nameIndex { return nameIndex.places(of: name, in: listedItems) }
        return listedItems.indices.filter { ExactName.areSame(listedItems[$0].name, name) }
    }

    /// The place of an entry that was at `hint`, or near it, in an earlier list.
    private func place(of item: FileItem, near hint: Int) -> Int? {
        if listedItems.indices.contains(hint), ExactName.areSame(listedItems[hint].name, item.name) { return hint }
        return ListWork.twin(of: item, among: places(ofExactly: item.name), in: listedItems)
    }

    /// The place of a name in `items`: the entry written exactly like it, else one that reads
    /// the same.
    private func index(ofName name: String, near hint: Int? = nil) -> Int? {
        if let hint, items.indices.contains(hint), ExactName.areSame(items[hint].name, name) { return hint }
        for place in places(ofExactly: name) {
            if let shown = shownIndex(ofPlace: place) { return shown }
        }
        return alike(name)
    }

    /// A shown entry whose name reads like `name` and is written differently.
    private func alike(_ name: String) -> Int? {
        // A name of plain ASCII reads like no other writing than its own composed form, and
        // that is looked up as it is written.
        let composed = name.precomposedStringWithCanonicalMapping
        if !ExactName.areSame(composed, name) {
            for place in places(ofExactly: composed) {
                if let shown = shownIndex(ofPlace: place) { return shown }
            }
        }
        if alikeIndex == nil {
            alikeLookups += 1
            guard alikeLookups > 2, items.count > 64 else { return items.firstIndex { $0.name == name } }
            var index: [String: Int] = [:]
            for (row, item) in items.enumerated()
            where !item.name.utf8.allSatisfy({ $0 < 0x80 }) && index[item.name] == nil {
                index[item.name] = row
            }
            alikeIndex = index
        }
        return alikeIndex?[name]
    }

    /// The shown entries a name stands for: all that are written exactly like it (a list
    /// gathered from several folders can hold a name more than once), else the one that reads
    /// the same.
    private func shownPlaces(named name: String) -> [Int] {
        let exact = places(ofExactly: name).filter { shownIndex(ofPlace: $0) != nil }
        if !exact.isEmpty { return exact }
        return alike(name).map { [place(ofShown: $0)] } ?? []
    }

    public var cursorItem: FileItem? { item(atRow: cursor) }

    /// The file under the cursor; nil on a folder and on `[..]`.
    public var cursorFile: FileItem? { cursorItem.flatMap { $0.isFolder ? nil : $0 } }

    /// True while the cursor is on the `[..]` row.
    public var cursorIsOnParentRow: Bool { hasParentRow && cursor == 0 }

    public func isSelected(row: Int) -> Bool {
        let index = row - offset
        return !marks.isEmpty && items.indices.contains(index) && marks.contains(place(ofShown: index))
    }

    /// Whether this entry of the list is marked: the entry itself, not another whose name
    /// merely reads the same. Of several entries with the very same name, the one at the
    /// item's location.
    public func isSelected(_ item: FileItem) -> Bool {
        guard !marks.isEmpty else { return false }
        let found = places(ofExactly: item.name)
        guard found.count > 1 else { return found.first.map(marks.contains) ?? false }
        // Several entries of this very name: the one that is this item; if none is quite
        // (the item is an older reading), the likeliest of those that are shown.
        if let own = found.first(where: { listedItems[$0] == item }) { return marks.contains(own) }
        let shown = found.filter { shownIndex(ofPlace: $0) != nil }
        return ListWork.twin(of: item, among: shown.isEmpty ? found : shown, in: listedItems).map(marks.contains)
            ?? false
    }

    /// Moves the cursor from a command; the row is kept inside the list.
    public func moveCursor(to row: Int) {
        cursor = max(0, min(row, max(rowCount - 1, 0)))
        changed(.cursor)
    }

    // MARK: Taking lists

    /// Puts lists in the place of the present ones, which the caller gets back in their
    /// stead, to look at and then to release in the background (`Discard`).
    private func take(listed: inout [FileItem], shown: inout [FileItem], places: [UInt32]?) {
        swap(&listedItems, &listed)
        swap(&items, &shown)
        shownPlaces = places
    }

    /// What was kept about the lists is no longer true; `list` when the entries or their
    /// order changed, and not only which of them are shown.
    private func arrangementChanged(list: Bool, index: NameIndex? = nil) {
        stamp += 1
        if list {
            listVersion += 1
            (nameIndex, lookups) = (index, 0)
        }
        (alikeIndex, alikeLookups) = (nil, 0)
    }

    private func setListTotals(_ tally: Tally?) {
        listTotals = tally.map { Totals(totalBytes: $0.bytes, totalFiles: $0.files, totalFolders: $0.folders) }
        listTotalsArePlain = tally?.isPlain ?? false
    }

    /// The saved marks no longer go by places: the list they are places of is about to go.
    private func keepSavedMarksByName() {
        guard case .places(let places) = saved else { return }
        if places.count <= 4_096 {
            var names = Set<ExactName>(minimumCapacity: places.count)
            places.forEach { names.insert(ExactName(listedItems[$0].name)) }
            saved = .names(names)
        } else {
            // Too many to make names of on the main thread: the list stays behind for them.
            saved = .remains(Remains(listedItems), places)
        }
    }

    private func sizedPlaces() -> Bitset {
        if let sized, sized.size == listedItems.count { return sized }
        let found = ListWork.sized(listedItems)
        sized = found
        return found
    }

    /// How the entries of a list that is replaced are found in the new one.
    fileprivate enum Moves {
        /// Every entry is where it was.
        case same
        /// The new place of every old one; `UInt32.max` for an entry that is gone.
        case table([UInt32])
        /// By their names, looked up when needed.
        case byName
    }

    /// Where the entry at `place` of the list `old` is in the present one. `shift` carries
    /// the distance of the last entry found from one call to the next.
    private func destination(of place: Int, in old: [FileItem], by moves: Moves, shift: inout Int) -> Int? {
        switch moves {
        case .same: return place

        case .table(let table):
            let to = table[place]
            return to == .max ? nil : Int(to)

        case .byName:
            guard let found = self.place(of: old[place], near: place + shift) else { return nil }
            shift = found - place
            return found
        }
    }

    private func moved(_ bits: Bitset, from old: [FileItem], by moves: Moves) -> Bitset {
        if case .same = moves, bits.size == listedItems.count { return bits }
        var result = Bitset(size: listedItems.count)
        var shift = 0
        bits.forEach { place in
            if let to = destination(of: place, in: old, by: moves, shift: &shift) { result.insert(to) }
        }
        return result
    }

    /// Takes a list in the place of the present one, of which it is another order or a later
    /// reading: the marks, the saved marks and the calculated sizes stay with their entries.
    /// A later reading (`isNewReading`) takes the sizes for its folders only.
    private func replace(
        listed: inout [FileItem], shown: inout [FileItem], places: [UInt32]?, moves: Moves, index: NameIndex?,
        tally: Tally?, keepsTotals: Bool, isNewReading: Bool
    ) {
        let (oldMarks, oldSized) = (marks, sizedPlaces())
        let oldTotals = (listTotals, listTotalsArePlain, selectedTotals)
        take(listed: &listed, shown: &shown, places: places)
        // `listed` holds the old list from here on, for as long as its entries are looked at.
        arrangementChanged(list: true, index: index)
        var moves = moves
        if case .byName = moves, oldMarks.count + oldSized.count > Self.indexedAbove {
            // Very many entries to find again by name: all of them at once, on all cores.
            let finder = NameFinder(listedItems, index: nameIndex)
            moves = .table(ListWork.moves(from: listed, to: finder))
            nameIndex = finder.index
        }
        var kept = moved(oldMarks, from: listed, by: moves)
        if places != nil, !kept.isEmpty { kept.formIntersection(shownBits()) }
        marks = kept
        if case .places(let places) = saved { saved = .places(moved(places, from: listed, by: moves)) }
        // Calculated sizes the new list does not have (they were set while it was worked
        // out, or it knows none) are carried over.
        var newSized = Bitset(size: listedItems.count)
        var writes: [(place: Int, size: Int64?)] = []
        if !oldSized.isEmpty {
            var shift = 0
            oldSized.forEach { place in
                guard let to = destination(of: place, in: listed, by: moves, shift: &shift) else { return }
                let size = listed[place].computedSize
                if listedItems[to].computedSize != size {
                    guard !isNewReading || listedItems[to].isFolder else { return }
                    writes.append((to, size))
                }
                if size != nil { newSized.insert(to) }
            }
        }
        if !writes.isEmpty {
            // Without a filter both lists are one piece of memory; it is changed once and
            // shared again instead of being copied for each.
            let isShared = shownPlaces == nil
            if isShared { items = [] }
            for (place, size) in writes {
                listedItems[place].computedSize = size
                if !isShared, let shown = shownIndex(ofPlace: place) { items[shown].computedSize = size }
            }
            if isShared { items = listedItems }
        }
        sized = newSized
        if keepsTotals, writes.isEmpty {
            (listTotals, listTotalsArePlain, selectedTotals) = oldTotals
        } else {
            setListTotals(writes.isEmpty ? tally : nil)
            selectedTotals = nil
        }
        Discard.later(&listed)
        Discard.later(&shown)
    }

    // MARK: Opening a directory before it has been read

    /// Everything a panel shows, kept so that a directory change that fails can be taken
    /// back: the lists with the filter they were shown through and the order they are in.
    public struct Snapshot: Sendable {
        fileprivate let directory: URL
        /// The listed and the shown items; released in the background when the snapshot goes.
        fileprivate let lists: Remains
        fileprivate let places: [UInt32]?
        fileprivate let index: NameIndex?
        fileprivate let cursor: Int
        fileprivate let marks: Bitset
        fileprivate let sized: Bitset?
        /// The filter the panel showed its list through. Whoever keeps a filter of its own
        /// beside the model's (the text of a quick filter) puts it back along with `restore`.
        public let filter: PanelFilter?
        /// The order the lists are in.
        public let sort: ListOrder
        fileprivate let parent: URL?
        fileprivate let root: URL
        fileprivate let volume: VolumeInfo?
        fileprivate let isListed: Bool
        fileprivate let isComplete: Bool
        fileprivate let isRefreshing: Bool
        fileprivate let history: [URL]
        fileprivate let historyIndex: Int
        fileprivate let isInArrivalOrder: Bool
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            directory: directory, lists: Remains(listedItems, items), places: shownPlaces, index: nameIndex,
            cursor: cursor, marks: marks,
            sized: sized, filter: filter, sort: sort, parent: parent, root: root, volume: volume, isListed: isListed,
            isComplete: isComplete, isRefreshing: isRefreshing, history: history, historyIndex: historyIndex,
            isInArrivalOrder: isInArrivalOrder)
    }

    /// Goes back to what the panel showed when the snapshot was taken: the same entries
    /// through the same filter. The order is the panel's present one: if it was changed
    /// since, the list is put into it, so the order shown and the order named always agree
    /// (a sort on the calling thread, in that one case; otherwise this costs nothing).
    public func restore(_ snapshot: Snapshot) {
        keepSavedMarksByName()
        directory = snapshot.directory
        var (listed, shown) = (snapshot.lists.lists[0], snapshot.lists.lists[1])
        take(listed: &listed, shown: &shown, places: snapshot.places)
        Discard.later(&listed)
        Discard.later(&shown)
        (cursor, marks, sized, filter) = (snapshot.cursor, snapshot.marks, snapshot.sized, snapshot.filter)
        setListTotals(nil)
        selectedTotals = nil
        arrangementChanged(list: true, index: snapshot.index)
        (parent, root, volume) = (snapshot.parent, snapshot.root, snapshot.volume)
        (isListed, isComplete, isRefreshing) = (snapshot.isListed, snapshot.isComplete, snapshot.isRefreshing)
        (history, historyIndex, isInArrivalOrder) = (
            snapshot.history, snapshot.historyIndex, snapshot.isInArrivalOrder
        )
        (isOpening, pendingFocus) = (false, nil)
        let wanted = requestedSort ?? sort
        requestedSort = nil
        sort = snapshot.sort
        if wanted != snapshot.sort {
            // Announces the change itself.
            _ = take(Self.prepare(Basis(self, discards: false), sort: wanted, indexing: false))
        } else {
            changed(.contents)
        }
    }

    /// True between `open(_:)` and the first entries: the panel is in the directory, but
    /// nothing of it has been read yet.
    public private(set) var isOpening = false

    /// Enters a directory at once, before anything of it has been read: the panel shows its
    /// path and an empty list (with `[..]`, so the way back is open), and the entries follow
    /// through `show` and `extend`. `parent` and `root` come from the file system's own
    /// arithmetic on the location, which needs no reading. If the reading fails, `restore`
    /// takes the panel back.
    public func open(_ directory: URL, parent: URL?, root: URL, history effect: HistoryEffect = .record) {
        keepSavedMarksByName()
        self.directory = directory.standardized
        (self.parent, self.root, volume) = (parent, root, nil)
        var (listed, shown): ([FileItem], [FileItem]) = ([], [])
        take(listed: &listed, shown: &shown, places: nil)
        Discard.later(&listed)
        Discard.later(&shown)
        (marks, sized, cursor) = (Bitset(), nil, 0)
        setListTotals(nil)
        selectedTotals = nil
        arrangementChanged(list: true)
        (isListed, isComplete, isRefreshing, isOpening, pendingFocus) = (false, false, false, true, nil)
        isInArrivalOrder = true
        record(effect)
        changed(.contents)
    }

    private func record(_ effect: HistoryEffect) {
        switch effect {
        case .record:
            if !history[historyIndex].isSameLocation(as: directory) {
                history.removeSubrange((historyIndex + 1)...)
                history.append(directory)
                if history.count > Self.historyLimit { history.removeFirst() }
                historyIndex = history.count - 1
            }

        case .step(let delta):
            historyIndex = max(0, min(historyIndex + delta, history.count - 1))

        case .keep:
            break
        }
    }

    // MARK: Listings

    /// Shows a directory that was just read. The selection starts empty and the cursor goes to
    /// `focus`, or to the top. With `complete: false` this is only the first piece; more follow
    /// through `extend`, and `finishLoading` ends it. After `open`, `effect` is not applied
    /// again: the visit is already in the history.
    ///
    /// `presorted` names the order the listing's items are already in, when they were sorted in
    /// the background; they are then taken as they are if that is still the panel's order.
    public func show(
        _ listing: Listing, focus: String? = nil, history effect: HistoryEffect = .record, complete: Bool = true,
        presorted: ListOrder? = nil
    ) {
        present(listing, focus: focus, history: effect, complete: complete, remembered: false, presorted: presorted)
    }

    /// Shows an earlier reading of a directory, kept in memory, while the directory is read
    /// afresh. The list can be used at once; until the fresh reading arrives through
    /// `update(with:)`, `isRefreshing` is true and `isComplete` false. Should the fresh reading
    /// fail, the caller goes back with `restore`.
    public func showRemembered(
        _ listing: Listing, focus: String? = nil, history effect: HistoryEffect = .record,
        presorted: ListOrder? = nil
    ) {
        present(listing, focus: focus, history: effect, complete: false, remembered: true, presorted: presorted)
    }

    /// `arranged` is what the filter shows of the listing's items, when the caller has
    /// worked that out (the items are then in the panel's order).
    private func present(
        _ listing: Listing, focus: String?, history effect: HistoryEffect, complete: Bool, remembered: Bool,
        presorted: ListOrder?, adoptingRequest: Bool = true, arranged: (shown: [FileItem], places: [UInt32]?)? = nil,
        index: NameIndex? = nil, tally: Tally? = nil
    ) {
        // The list that arrives is taken in the order the user asked for, if one is waiting.
        if adoptingRequest, let requestedSort { adoptSort(requestedSort) }
        // After `open` the history already holds this visit; the directory just read may still
        // differ from the one that was opened (the location of a file leads to its folder).
        let wasOpening = isOpening
        keepSavedMarksByName()
        adopt(listing)
        isComplete = complete
        isRefreshing = remembered
        // More pieces follow only for a directory that is still arriving.
        pendingFocus = complete || remembered ? nil : focus
        var listed = presorted == sort ? listing.items : Sorter.sort(listing.items, by: sort)
        var (shown, places) = arranged ?? ListWork.arrange(listed, by: filter)
        let count = listed.count
        take(listed: &listed, shown: &shown, places: places)
        Discard.later(&listed)
        Discard.later(&shown)
        (marks, sized) = (Bitset(size: count), nil)
        setListTotals(tally)
        selectedTotals = nil
        arrangementChanged(list: true, index: index)
        isInArrivalOrder = sort.key == .unsorted
        cursor = focus.flatMap(row(ofName:)) ?? 0
        if wasOpening {
            history[historyIndex] = directory
        } else {
            record(effect)
        }
        changed(.contents)
    }

    /// A directory that is arriving piece by piece has grown: `listed` is everything that has
    /// come so far, sorted by `order` in the background. The cursor stays on its item and the
    /// selection is kept. The list is taken as it is when that is still the panel's order, so
    /// the main thread does no sorting. What is left to it here grows with the list: the
    /// filter is asked about every entry, and the marked entries and the cursor's are found
    /// again by name. **Not for the main thread on long lists**: `prepare(_:extendingTo:
    /// sortedBy:)` does all of that in the background.
    public func extend(to listed: [FileItem], sortedBy order: ListOrder) {
        if let requestedSort { adoptSort(requestedSort) }
        var grown = order == sort ? listed : Sorter.sort(listed, by: sort)
        var (shown, places) = ListWork.arrange(grown, by: filter)
        extend(to: &grown, shown: &shown, places: places, moves: .byName, index: nil, tally: nil)
    }

    private func extend(
        to listed: inout [FileItem], shown: inout [FileItem], places: [UInt32]?, moves: Moves, index: NameIndex?,
        tally: Tally?
    ) {
        let cursorName = cursorItem?.name
        let wasOnParentRow = cursorIsOnParentRow
        replace(
            listed: &listed, shown: &shown, places: places, moves: moves, index: index, tally: tally,
            keepsTotals: false, isNewReading: true)
        isInArrivalOrder = sort.key == .unsorted
        if let focus = pendingFocus, let row = row(ofName: focus) {
            // The item the panel was asked to show has arrived.
            cursor = row
            pendingFocus = nil
        } else if let cursorName, let row = row(ofName: cursorName) {
            cursor = row
        } else if !wasOnParentRow {
            cursor = min(cursor, max(rowCount - 1, 0))
        }
        changed(.contents)
    }

    /// The directory has arrived completely.
    public func finishLoading() {
        guard !isComplete else { return }
        isComplete = true
        isRefreshing = false
        isOpening = false
        pendingFocus = nil
        changed(.contents)
    }

    /// Takes a fresh listing of the directory already shown and keeps the cursor item, the
    /// selection and calculated folder sizes. Returns false when nothing visible changed; a
    /// listing that holds the entries the panel has already leaves the list, and
    /// `listVersion`, as they are.
    ///
    /// The work is done here, on the calling thread: comparing the lists, and for a listing
    /// that differs, filtering it and finding the marked entries again. **Not for the main
    /// thread on long lists**: that is `prepare(_:update:focus:presorted:)` in the
    /// background and `apply` here.
    @discardableResult
    public func update(with listing: Listing, focus: String? = nil, presorted: ListOrder? = nil) -> Bool {
        take(
            Self.prepare(
                Basis(self, discards: false), update: listing, focus: focus, presorted: presorted, tabulating: false))
            == .changed
    }

    private func adopt(_ listing: Listing) {
        directory = listing.directory.standardized
        parent = listing.parent
        root = listing.root
        volume = listing.volume
        isListed = true
        isComplete = true
        isRefreshing = false
        isOpening = false
        pendingFocus = nil
    }

    // MARK: Changes worked out in the background

    /// What a change of the list is worked out from: the lists as they are now, with the
    /// filter and the order. Taken on the main thread, which costs nothing (the lists are
    /// shared, not copied), and handed to a `prepare` function on any thread.
    ///
    /// Unchecked: the lists are changed only in `deinit`, when nobody else holds the basis.
    public final class Basis: @unchecked Sendable {
        /// `PanelModel.listVersion` when the basis was taken.
        public let listVersion: Int
        public let directory: URL
        public private(set) var listedItems: [FileItem]
        public private(set) var items: [FileItem]
        public let filter: PanelFilter?
        public let sort: ListOrder
        /// `PanelModel.requestedSort` when the basis was taken.
        public let requestedSort: ListOrder?
        /// The order a list that arrives is put into: the requested one, else the present one.
        fileprivate var wantedSort: ListOrder { requestedSort ?? sort }
        fileprivate let stamp: Int
        fileprivate let sizeStamp: Int
        fileprivate let places: [UInt32]?
        fileprivate let index: NameIndex?
        fileprivate let sized: Bitset?
        private let discards: Bool

        @MainActor fileprivate init(_ model: PanelModel, discards: Bool) {
            (listVersion, directory, listedItems, items) = (
                model.listVersion, model.directory, model.listedItems, model.items
            )
            (filter, sort, stamp, places) = (model.filter, model.sort, model.stamp, model.shownPlaces)
            (sizeStamp, requestedSort) = (model.sizeStamp, model.requestedSort)
            (index, sized) = (model.nameIndex, model.sized.flatMap { $0.size == model.listedItems.count ? $0 : nil })
            self.discards = discards
        }

        deinit {
            // The model may have moved on; then this is the last holder of a long list.
            guard discards else { return }
            Discard.later(&listedItems)
            Discard.later(&items)
        }
    }

    /// The model as it is now, for a `prepare` function.
    public var basis: Basis { Basis(self, discards: true) }

    /// A change of the list, worked out by a `prepare` function and waiting for `apply`.
    /// Whatever it holds is released in the background, taken or not.
    ///
    /// Unchecked: made on one thread and handed to the main thread, which alone changes it
    /// from then on (`apply`).
    public final class Prepared: @unchecked Sendable {
        fileprivate enum Kind {
            case sort
            case filter
            /// A fresh reading of the directory the panel shows; `isSame` when it holds the
            /// entries the panel has.
            case update(Listing, focus: String?, isSame: Bool)
            /// A reading of another directory, entered as `show` or `showRemembered` enter it.
            case show(Listing, focus: String?, history: HistoryEffect, complete: Bool, remembered: Bool)
            case extend
            /// Calculated sizes written into copies of the lists, which are otherwise as they
            /// were: good for as long as no other size was set (`sizeStamp`). `sized` is the
            /// places that have a size now.
            case sizes(sizeStamp: Int, sized: Bitset)
        }

        fileprivate private(set) var kind: Kind
        fileprivate let stamp: Int
        fileprivate var listed: [FileItem]
        fileprivate var shown: [FileItem]
        fileprivate let places: [UInt32]?
        fileprivate let index: NameIndex?
        fileprivate let tally: Tally?
        fileprivate let sort: ListOrder
        fileprivate let filter: PanelFilter?
        fileprivate let moves: Moves

        fileprivate init(
            _ kind: Kind, from basis: Basis, listed: [FileItem], shown: [FileItem], places: [UInt32]?,
            index: NameIndex?,
            tally: Tally?, sort: ListOrder, filter: PanelFilter?, moves: Moves
        ) {
            (self.kind, stamp, self.listed, self.shown, self.places) = (kind, basis.stamp, listed, shown, places)
            (self.index, self.tally, self.sort, self.filter, self.moves) = (index, tally, sort, filter, moves)
        }

        /// The lists are the model's now, or its own again: nothing is left to release.
        fileprivate func forget() {
            (listed, shown) = ([], [])
        }

        deinit {
            Discard.later(&listed)
            Discard.later(&shown)
            // The reading itself, which `kind` keeps: when the folder was found as it was,
            // this is the last holder of a list as long as the folder, and it goes where
            // this object goes, which is the main thread right after `apply`.
            var fresh: [FileItem] = []
            switch kind {
            case .update(let listing, _, _), .show(let listing, _, _, _, _): fresh = listing.items
            default: break
            }
            kind = .sort
            Discard.later(&fresh)
        }
    }

    /// What became of a prepared change.
    public enum Outcome: Sendable {
        /// The model has changed since the basis was taken (its list, filter or order):
        /// nothing was done. The caller takes a new basis and prepares again, in the background.
        case stale
        /// Applied, and nothing the panel shows is different (a refresh that found the
        /// directory as it was).
        case unchanged
        /// Applied; `onChange` was called.
        case changed

        public var wasApplied: Bool { self != .stale }
    }

    /// The list in another order. **For any thread.** Turning the direction round is one
    /// pass; anything else is a sort on all cores.
    public nonisolated static func prepare(_ basis: Basis, sort order: ListOrder) -> Prepared {
        prepare(basis, sort: order, indexing: true)
    }

    fileprivate nonisolated static func prepare(_ basis: Basis, sort order: ListOrder, indexing: Bool) -> Prepared {
        let old = basis.listedItems
        // The list is in the order of its basis: asked for that order again, it stays.
        guard order != basis.sort, let indexes = Sorter.resortedIndexes(of: old, from: basis.sort, to: order) else {
            return Prepared(
                .sort, from: basis, listed: old, shown: basis.items, places: basis.places, index: basis.index,
                tally: nil,
                sort: order, filter: basis.filter, moves: .same)
        }
        let listed = Sorter.permute(old, by: indexes)
        let table = [UInt32](unsafeUninitializedCapacity: indexes.count) { buffer, count in
            for (new, old) in indexes.enumerated() { buffer[Int(old)] = UInt32(new) }
            count = indexes.count
        }
        // What was shown is shown: the filter is not asked again.
        var shown = listed
        var places: [UInt32]?
        if let oldPlaces = basis.places {
            var isShown = Bitset(size: old.count)
            for place in oldPlaces { isShown.insert(Int(place)) }
            let kept = (0..<indexes.count).filter { isShown.contains(Int(indexes[$0])) }.map { UInt32($0) }
            (shown, places) = (ListWork.picked(listed, at: kept), kept)
        }
        let index =
            basis.index.map { $0.moved(by: table) }
            ?? (indexing && listed.count > indexedAbove ? NameIndex(listed) : nil)
        return Prepared(
            .sort, from: basis, listed: listed, shown: shown, places: places, index: index, tally: nil, sort: order,
            filter: basis.filter, moves: .table(table))
    }

    /// The list through another filter; nil shows everything. **For any thread**: a long
    /// list is filtered on all cores, so `filter.matches` is called from several threads at
    /// once and must be a function of the entry alone.
    public nonisolated static func prepare(_ basis: Basis, filter: PanelFilter?) -> Prepared {
        let (shown, places) = ListWork.arrange(basis.listedItems, by: filter)
        return Prepared(
            .filter, from: basis, listed: basis.listedItems, shown: shown, places: places, index: basis.index,
            tally: ListWork.tally(shown), sort: basis.sort, filter: filter, moves: .same)
    }

    /// A fresh listing of the directory the panel shows, as `update(with:focus:presorted:)`
    /// takes it. **For any thread.** Everything that grows with the list is done here:
    /// sorting (unless `presorted` is the panel's order), comparing with what the panel has,
    /// carrying over calculated folder sizes, filtering, and finding the place every old
    /// entry has in the new list, so that `apply` only moves the marks.
    public nonisolated static func prepare(
        _ basis: Basis, update listing: Listing, focus: String? = nil, presorted: ListOrder? = nil
    ) -> Prepared {
        prepare(basis, update: listing, focus: focus, presorted: presorted, tabulating: true)
    }

    fileprivate nonisolated static func prepare(
        _ basis: Basis, update listing: Listing, focus: String?, presorted: ListOrder?, tabulating: Bool
    ) -> Prepared {
        // A list that arrives is put into the order the user asked for, if one is waiting.
        let order = basis.wantedSort
        var listed = presorted == order ? listing.items : Sorter.sort(listing.items, by: order)
        let old = basis.listedItems
        guard listing.directory.isSameLocation(as: basis.directory) else {
            let (shown, places) = ListWork.arrange(listed, by: basis.filter)
            return Prepared(
                .show(listing, focus: focus, history: .keep, complete: true, remembered: false), from: basis,
                listed: listed,
                shown: shown, places: places,
                index: tabulating && listed.count > indexedAbove ? NameIndex(listed) : nil,
                tally: ListWork.tally(shown),
                sort: order, filter: basis.filter, moves: .byName)
        }
        if order == basis.sort, ListWork.areSameEntries(listed, old) {
            return Prepared(
                .update(listing, focus: focus, isSame: true), from: basis, listed: old, shown: basis.items,
                places: basis.places,
                index: basis.index, tally: nil, sort: basis.sort, filter: basis.filter, moves: .same)
        }
        let finder = NameFinder(listed)
        // Folder sizes calculated with Space are carried over to the fresh entries.
        let sized = basis.sized ?? ListWork.sized(old)
        if !sized.isEmpty {
            var writes: [(place: Int, size: Int64?)] = []
            var shift = 0
            sized.forEach { place in
                guard let found = finder.place(of: old[place], near: place + shift) else { return }
                shift = found - place
                if listed[found].isFolder { writes.append((found, old[place].computedSize)) }
            }
            for (place, size) in writes { listed[place].computedSize = size }
        }
        let table = tabulating ? ListWork.moves(from: old, to: finder) : nil
        let (shown, places) = ListWork.arrange(listed, by: basis.filter)
        return Prepared(
            .update(listing, focus: focus, isSame: false), from: basis, listed: listed, shown: shown, places: places,
            index: finder.index, tally: ListWork.tally(shown), sort: order, filter: basis.filter,
            moves: table.map(Moves.table) ?? .byName)
    }

    /// Entering a directory that was read (or, with `remembered`, read earlier and kept), as
    /// `show(_:focus:history:complete:presorted:)` and `showRemembered` enter it. **For any
    /// thread.** Everything that grows with the list is done here: sorting (unless
    /// `presorted` is the order a list that arrives is put into), the filter over every
    /// entry, the index of names the cursor is found by, and the totals; `apply` then puts
    /// the lists in place, moves the cursor to `focus` and records the visit.
    ///
    /// `apply` answers `.stale` when the panel's list, filter or order changed since the
    /// basis was taken (the folder it showed was read again, another order was chosen):
    /// the caller takes a new basis and prepares again, in the background.
    public nonisolated static func prepare(
        _ basis: Basis, show listing: Listing, focus: String? = nil, history: HistoryEffect = .record,
        complete: Bool = true, remembered: Bool = false, presorted: ListOrder? = nil
    ) -> Prepared {
        let order = basis.wantedSort
        let listed = presorted == order ? listing.items : Sorter.sort(listing.items, by: order)
        let (shown, places) = ListWork.arrange(listed, by: basis.filter)
        return Prepared(
            .show(
                listing, focus: focus, history: history, complete: remembered ? false : complete,
                remembered: remembered),
            from: basis, listed: listed, shown: shown, places: places,
            index: listed.count > indexedAbove ? NameIndex(listed) : nil,
            tally: ListWork.tally(shown), sort: order, filter: basis.filter, moves: .byName)
    }

    /// A directory that is arriving piece by piece, grown to `listed` (sorted by `order`), as
    /// `extend(to:sortedBy:)` takes it. **For any thread.**
    public nonisolated static func prepare(_ basis: Basis, extendingTo listed: [FileItem], sortedBy order: ListOrder)
        -> Prepared
    {
        let wanted = basis.wantedSort
        let grown = order == wanted ? listed : Sorter.sort(listed, by: wanted)
        let finder = NameFinder(grown)
        let table = ListWork.moves(from: basis.listedItems, to: finder)
        let (shown, places) = ListWork.arrange(grown, by: basis.filter)
        return Prepared(
            .extend, from: basis, listed: grown, shown: shown, places: places, index: finder.index,
            tally: ListWork.tally(shown),
            sort: wanted, filter: basis.filter, moves: .table(table))
    }

    /// Calculated folder sizes for entries of the list, by name, as `setComputedSizes` takes
    /// them. **For any thread.** The sizes are written into a copy of the list that is made
    /// here, so that `apply` only puts the copy in the list's place: for a caller whose list
    /// is held by somebody else as well (see `setComputedSizes`), who would otherwise pay
    /// for that copy on the main thread. A name stands for the entries written exactly like
    /// it, else for the entry whose name is its composed form.
    ///
    /// `apply` answers `.stale` when the list, the filter or the order changed since the
    /// basis was taken, **or another size was set**: the caller takes a new basis and
    /// prepares again. `.unchanged` when no name was found.
    public nonisolated static func prepare(_ basis: Basis, computedSizes sizes: [(name: String, size: Int64)])
        -> Prepared
    {
        let old = basis.listedItems
        let finder = NameFinder(old, index: basis.index)
        var targets: [(place: Int, size: Int64)] = []
        for (name, size) in sizes {
            var found = finder.places(of: name)
            if found.isEmpty {
                let composed = name.precomposedStringWithCanonicalMapping
                if !ExactName.areSame(composed, name) { found = finder.places(of: composed) }
            }
            for place in found { targets.append((place, size)) }
        }
        var known = basis.sized ?? ListWork.sized(old)
        guard !targets.isEmpty else {
            return Prepared(
                .sizes(sizeStamp: basis.sizeStamp, sized: known), from: basis, listed: [], shown: [],
                places: basis.places,
                index: finder.index, tally: nil, sort: basis.sort, filter: basis.filter, moves: .same)
        }
        // The basis holds the list too, so the first write below makes the copy: here, not
        // on the main thread.
        var listed = old
        for (place, size) in targets {
            listed[place].computedSize = size
            known.insert(place)
        }
        var shown = listed
        if let places = basis.places {
            shown = basis.items
            for (place, size) in targets {
                var (low, high) = (0, places.count)
                while low < high {
                    let middle = (low + high) / 2
                    if Int(places[middle]) < place { low = middle + 1 } else { high = middle }
                }
                if low < places.count, Int(places[low]) == place { shown[low].computedSize = size }
            }
        }
        return Prepared(
            .sizes(sizeStamp: basis.sizeStamp, sized: known), from: basis, listed: listed, shown: shown,
            places: basis.places,
            index: finder.index, tally: ListWork.tally(shown), sort: basis.sort, filter: basis.filter, moves: .same)
    }

    /// Takes a prepared change, if the model's list, filter and order are still what they
    /// were when its basis was taken; otherwise nothing happens and the answer is `.stale`:
    /// the caller starts again from a new basis, in the background. Marks, the cursor and
    /// calculated sizes that changed in the meantime are not in the way; they are taken as
    /// they are now. A prepared change is applied once.
    @discardableResult
    public func apply(_ prepared: Prepared) -> Outcome {
        MainThread.assert("A panel model")
        return take(prepared)
    }

    private func take(_ prepared: Prepared) -> Outcome {
        guard prepared.stamp == stamp else { return .stale }
        switch prepared.kind {
        case .show(let listing, let focus, let history, let complete, let remembered):
            let sorted = Listing(
                directory: listing.directory, items: prepared.listed, parent: listing.parent, root: listing.root,
                volume: listing.volume)
            adoptSort(prepared.sort)
            present(
                sorted, focus: focus, history: history, complete: complete, remembered: remembered, presorted: sort,
                adoptingRequest: false,
                arranged: (prepared.shown, prepared.places), index: prepared.index, tally: prepared.tally)
            prepared.forget()
            return .changed

        case .sort:
            // Another order has been asked for since: this one is no longer wanted.
            if let requestedSort, requestedSort != prepared.sort { return .stale }
            let cursorPlace = cursorItem == nil ? nil : place(ofShown: cursor - offset)
            adoptSort(prepared.sort)
            guard case .table = prepared.moves else {
                // The list is in the new order as it is; only the name of the order changes.
                prepared.forget()
                stamp += 1
                changed(.contents)
                return .changed
            }
            replace(
                listed: &prepared.listed, shown: &prepared.shown, places: prepared.places, moves: prepared.moves,
                index: prepared.index,
                tally: nil, keepsTotals: true, isNewReading: false)
            var shift = 0
            if let cursorPlace, let to = destination(of: cursorPlace, in: [], by: prepared.moves, shift: &shift),
                let index = shownIndex(ofPlace: to)
            {
                cursor = index + offset
            }
            changed(.contents)
            return .changed

        case .filter:
            let cursorPlace = cursorItem == nil ? nil : place(ofShown: cursor - offset)
            filter = prepared.filter
            swap(&items, &prepared.shown)
            shownPlaces = prepared.places
            // What was shown before goes in the background; the list itself stays.
            Discard.later(&prepared.shown)
            prepared.forget()
            // Sizes that were calculated while the filter was at work are in the list, not in
            // the copies the filter made.
            if shownPlaces != nil, let sized, !sized.isEmpty {
                sized.forEach { place in
                    if let shown = shownIndex(ofPlace: place),
                        items[shown].computedSize != listedItems[place].computedSize
                    {
                        items[shown].computedSize = listedItems[place].computedSize
                    }
                }
            }
            // Items that are no longer shown lose their marks.
            if shownPlaces != nil, !marks.isEmpty { marks.formIntersection(shownBits()) }
            setListTotals(prepared.tally)
            selectedTotals = nil
            arrangementChanged(list: false)
            cursor =
                cursorPlace.flatMap(shownIndex(ofPlace:)).map { $0 + offset } ?? min(cursor, max(rowCount - 1, 0))
            changed(.contents)
            return .changed

        case .update(let listing, let focus, let isSame):
            let focusName = focus ?? cursorItem?.name
            let (oldCursor, oldVolume, wasListed, wasComplete, wasRefreshing) = (
                cursor, volume, isListed, isComplete, isRefreshing
            )
            adopt(listing)
            if isSame {
                prepared.forget()
            } else {
                adoptSort(prepared.sort)
                replace(
                    listed: &prepared.listed, shown: &prepared.shown, places: prepared.places, moves: prepared.moves,
                    index: prepared.index,
                    tally: prepared.tally, keepsTotals: false, isNewReading: true)
                isInArrivalOrder = sort.key == .unsorted
            }
            // A vanished cursor item leaves the cursor on the row that took its place (07 › State changes).
            // In a list that did not change, the item is where it was.
            cursor =
                focusName.flatMap { index(ofName: $0, near: oldCursor - offset) }.map { $0 + offset }
                ?? min(oldCursor, max(rowCount - 1, 0))
            // The flags count as well: whoever shows "refreshing" has to hear that it is over.
            let isDifferent =
                !isSame || cursor != oldCursor || volume != oldVolume || !wasListed || isComplete != wasComplete
                || isRefreshing != wasRefreshing
            if isDifferent { changed(.contents) }
            return isDifferent ? .changed : .unchanged

        case .extend:
            adoptSort(prepared.sort)
            extend(
                to: &prepared.listed, shown: &prepared.shown, places: prepared.places, moves: prepared.moves,
                index: prepared.index,
                tally: prepared.tally)
            return .changed

        case .sizes(let sizeStamp, let sized):
            guard sizeStamp == self.sizeStamp else { return .stale }
            // No name was found: the lists stay.
            guard prepared.listed.count == listedItems.count, !listedItems.isEmpty else { return .unchanged }
            // The same entries in the same places: the marks, the cursor, the index of names
            // and the versions stay as they are.
            swap(&listedItems, &prepared.listed)
            swap(&items, &prepared.shown)
            if nameIndex == nil { nameIndex = prepared.index }
            self.sized = sized
            setListTotals(prepared.tally)
            selectedTotals = nil
            self.sizeStamp += 1
            changed(.selection)
            return .changed
        }
    }

    // MARK: Where navigation leads

    /// The parent directory, and the name of the folder being left: the cursor lands on it.
    public var parentTarget: (location: URL, focus: String)? {
        parent.map { ($0, directory.lastPathComponent) }
    }

    /// The root directory, and the folder below it that was part of the old path.
    public var rootTarget: (location: URL, focus: String?)? {
        guard !root.isSameLocation(as: directory) else { return nil }
        let below = directory.pathComponents.dropFirst(root.pathComponents.count).first
        return (root, below)
    }

    public var backLocation: URL? { historyIndex > 0 ? history[historyIndex - 1] : nil }
    public var forwardLocation: URL? { historyIndex < history.count - 1 ? history[historyIndex + 1] : nil }

    /// The most recent place of the history before the current one that `isWanted` accepts
    /// (the folder the user came from before entering a volume that is about to go away).
    public func lastVisited(where isWanted: (URL) -> Bool) -> URL? {
        history[..<min(historyIndex, history.count)].last(where: isWanted)
    }

    // MARK: Sorting and filters

    /// Notes the order the user asked for without putting the list into it: costs nothing,
    /// and nothing is announced. From then on every list that arrives (`show`, `update`,
    /// `extend` and their `prepare` forms) is taken in this order and makes it the panel's;
    /// and a `prepare(_:sort:)` for another order is refused by `apply` as stale. So a caller
    /// that sorts a long list in the background (`prepare(_:sort:)`, `apply`) calls this
    /// first: when the directory changes while the sort is made, the reading that arrives
    /// brings the wanted order with it, and the sort need not be raced against the readings
    /// again and again. A later request replaces an earlier one; `setSort` and a successful
    /// `apply` of the wanted order end it.
    public func requestSort(_ order: ListOrder) {
        requestedSort = order == sort ? nil : order
    }

    /// Makes `order` the panel's, for a list that has just been taken in it.
    private func adoptSort(_ order: ListOrder) {
        if order != sort {
            sort = order
            if order.key != .unsorted { isInArrivalOrder = false }
        }
        if requestedSort == order { requestedSort = nil }
    }

    /// Sorts the list on the calling thread. Turning the direction of the same key round
    /// costs one pass; another key costs a sort. **Not for the main thread on long lists**:
    /// a caller with one sorts in the background, `prepare(_:sort:)`, then `apply`.
    ///
    /// Choosing `unsorted` after another key leaves the files as that key had them (see
    /// `isInArrivalOrder`).
    public func setSort(_ order: ListOrder) {
        requestedSort = nil
        _ = take(Self.prepare(Basis(self, discards: false), sort: order, indexing: false))
    }

    /// Takes a new order together with the list already in that order: `listedItems` as they
    /// were when `listVersion` was noted, sorted by `order` off the main thread. The caller
    /// checks that `listVersion` is still the same; a list of another length is not taken
    /// and the model sorts by itself. What the filter shows of the list and where the marked
    /// entries are in it is worked out here, on the calling thread: **not for the main
    /// thread on long lists**; `prepare(_:sort:)` and `apply` leave nothing of that to it.
    public func setSort(_ order: ListOrder, presorted sorted: [FileItem]) {
        guard sorted.count == listedItems.count else {
            setSort(order)
            return
        }
        let cursorName = cursorItem?.name
        requestedSort = nil
        sort = order
        if order.key != .unsorted { isInArrivalOrder = false }
        var listed = sorted
        var (shown, places) = ListWork.arrange(listed, by: filter)
        replace(
            listed: &listed, shown: &shown, places: places, moves: .byName, index: nil, tally: nil, keepsTotals: false,
            isNewReading: false)
        if let cursorName, let row = row(ofName: cursorName) { cursor = row }
        changed(.contents)
    }

    /// The same, with the check: `sorted` is taken only if `listVersion` is still `version`
    /// (and the list as long as it was). Otherwise nothing happens and the answer is false;
    /// the caller sorts again, in the background.
    @discardableResult
    public func setSort(_ order: ListOrder, presorted sorted: [FileItem], listVersion version: Int) -> Bool {
        guard version == listVersion, sorted.count == listedItems.count else { return false }
        setSort(order, presorted: sorted)
        return true
    }

    /// Shows only the entries that pass `filter`; nil shows all again. The cursor stays on its
    /// item when that is still shown, and items that are no longer shown lose their mark.
    ///
    /// A caller that knows the new filter lets through only what the present one does (a quick
    /// filter that was typed on) says `narrowing`: the shown items are then filtered, not all.
    ///
    /// The filter is asked about every entry here, on the calling thread (on all cores for
    /// a long list). **Not for the main thread on long lists**: `prepare(_:filter:)` in the
    /// background, then `apply`.
    public func setFilter(_ filter: PanelFilter?, narrowing: Bool = false) {
        let basis = Basis(self, discards: false)
        guard narrowing, let filter else {
            _ = take(Self.prepare(basis, filter: filter))
            return
        }
        let (shown, places) = ListWork.narrow(items, at: shownPlaces, by: filter)
        _ = take(
            Prepared(
                .filter, from: basis, listed: listedItems, shown: shown, places: places, index: nameIndex,
                tally: ListWork.tally(shown),
                sort: sort, filter: filter, moves: .same))
    }

    /// What `setFilter` shows of a list: the entries that pass `filter`, in the list's order.
    /// **For any thread**: a caller with a long list notes `listVersion`, takes `listedItems`,
    /// works this out in the background and hands it to `setFilter(_:prefiltered:listVersion:)`.
    /// A long list is filtered on all cores, so `filter.matches` is then called from several
    /// threads at once and must be a function of the entry alone.
    public nonisolated static func filtered(_ listed: [FileItem], by filter: PanelFilter?) -> [FileItem] {
        ListWork.arrange(listed, by: filter).shown
    }

    /// Takes a filter together with what it shows: `PanelModel.filtered(listedItems, by:
    /// filter)`, worked out off the main thread from the list as it was when `listVersion`
    /// was `version`. If the list has changed since, `shown` is not taken and the model
    /// filters by itself, as `setFilter(_:)` does; returns whether `shown` was taken. Either
    /// way the model ends up exactly as after `setFilter(filter)`.
    ///
    /// A caller that would rather filter again in the background than have the model do it
    /// here uses `prepare(_:filter:)` and `apply`, which never falls back. Because of that
    /// fall-back, and because the places of `shown` in the list are looked for here, this is
    /// **not for the main thread on long lists** either.
    @discardableResult
    public func setFilter(_ filter: PanelFilter?, prefiltered shown: [FileItem], listVersion version: Int) -> Bool {
        guard version == listVersion, filter != nil, shown.count != listedItems.count,
            let places = ListWork.places(of: shown, in: listedItems)
        else {
            setFilter(filter)
            return version == listVersion
        }
        _ = take(
            Prepared(
                .filter, from: Basis(self, discards: false), listed: listedItems, shown: shown, places: places,
                index: nameIndex,
                tally: nil, sort: sort, filter: filter, moves: .same))
        return true
    }

    /// Takes what the file system now says about the volume (its free space has changed)
    /// without reading the directory again.
    public func setVolume(_ volume: VolumeInfo?) {
        guard volume != self.volume else { return }
        self.volume = volume
        changed(.contents)
    }

    /// Takes effect when the directory is read again.
    public func setShowHidden(_ show: Bool) {
        showHidden = show
    }

    // MARK: Selection

    public func toggleSelection(row: Int) {
        let index = row - offset
        guard items.indices.contains(index) else { return }
        let place = place(ofShown: index)
        let isSelected = !marks.remove(place)
        if isSelected { marks.insert(place) }
        count(items[index], selected: isSelected)
        changed(.selection)
    }

    public func setSelected(_ selected: Bool, rows: ClosedRange<Int>) {
        // Rows outside the list are not walked: a range may be far longer than the list.
        let first = max(rows.lowerBound, offset) - offset
        let last = min(rows.upperBound, items.count - 1 + offset) - offset
        if first <= last {
            for index in first...last {
                let place = place(ofShown: index)
                if selected ? marks.insert(place) : marks.remove(place) { count(items[index], selected: selected) }
            }
        }
        changed(.selection)
    }

    /// Marks or unmarks the shown items with these names, and announces it once. A name
    /// stands for the items written exactly like it (in a list gathered from several folders
    /// that can be more than one), else for the item that reads the same, as `row(ofName:)`
    /// finds it. Every name is looked up (the first calls on a long list make an index of
    /// all its names): **not for the main thread with many names or on long lists**; the
    /// calls that take rows or indexes look nothing up.
    public func setSelected(_ selected: Bool, names: some Sequence<String>) {
        for name in names {
            // Only what is shown can be marked.
            for place in shownPlaces(named: name) where selected ? marks.insert(place) : marks.remove(place) {
                count(listedItems[place], selected: selected)
            }
        }
        changed(.selection)
    }

    /// Keeps the selected half of the totals in step with one item's mark.
    private func count(_ item: FileItem, selected: Bool) {
        guard var totals = selectedTotals else { return }
        if item.isFolder {
            totals.selectedFolders += selected ? 1 : -1
        } else {
            totals.selectedFiles += selected ? 1 : -1
        }
        let size = item.isFolder ? (item.computedSize ?? 0) : item.size
        // A size below zero makes the sum depend on its order: counted afresh.
        selectedTotals = size < 0 ? nil : totals.adding(bytes: selected ? size : -size, selected: true)
    }

    /// Makes the shown items with these names the whole selection, and announces it once.
    /// Looks every name up, like `setSelected(_:names:)`: **not for the main thread with
    /// many names or on long lists**.
    public func setSelection(names: some Sequence<String>) {
        var bits = Bitset(size: listedItems.count)
        for name in names {
            for place in shownPlaces(named: name) { bits.insert(place) }
        }
        setMarks(bits)
    }

    /// `totals` is the selected half of the totals, when the caller knows it.
    private func setMarks(_ bits: Bitset, totals: Totals? = nil) {
        marks = bits
        selectedTotals = totals
        changed(.selection)
    }

    /// Marks every shown item. However long the list, this takes no time worth the name: the
    /// marks are one bit per entry, and the figures of the status line are those of the list.
    public func selectAll() {
        _ = totals
        let all =
            listTotalsArePlain
            ? listTotals.map {
                Totals(selectedBytes: $0.totalBytes, selectedFiles: $0.totalFiles, selectedFolders: $0.totalFolders)
            } : nil
        setMarks(shownBits(), totals: all)
    }

    public func clearSelection() { setMarks(Bitset(size: listedItems.count), totals: Totals()) }

    public func invertSelection() {
        // The figures of the rest are those of the list less those of the marked.
        let (list, selected) = (totals, selectedTotals)
        var rest: Totals?
        if listTotalsArePlain, let selected {
            rest = Totals(
                selectedBytes: list.totalBytes - selected.selectedBytes,
                selectedFiles: list.totalFiles - selected.selectedFiles,
                selectedFolders: list.totalFolders - selected.selectedFolders)
        }
        var bits = shownBits()
        bits.subtract(marks)
        setMarks(bits, totals: rest)
    }

    /// Select group / Unselect group with a file mask. One pass over the list on all cores
    /// (about 15 ms for a million names), on the calling thread, like `select(where:)`.
    public func select(mask: String, select: Bool = true) {
        let mask = FileMask(mask)
        self.select(where: { mask.matches($0.name) }, select: select)
    }

    /// Marks (or unmarks) the shown items `matches` holds for, and announces it once. A long
    /// list is looked through on all cores: `matches` is then called from several threads at
    /// once and must be a function of the item alone. With a test that costs more than a
    /// look at the name this is **not for the main thread on long lists**: `rows(of:where:)`
    /// does it in the background.
    public func select(where matches: @Sendable (FileItem) -> Bool, select: Bool = true) {
        let found = ListWork.matching(listedItems, among: shownPlaces == nil ? nil : shownBits(), where: matches)
        var bits = marks
        if select { bits.formUnion(found) } else { bits.subtract(found) }
        setMarks(bits)
    }

    /// A set of shown rows of one model, as the list, the filter and the order were when its
    /// basis was taken.
    public struct RowSet: Sendable {
        fileprivate let stamp: Int
        fileprivate let bits: Bitset
        /// How many rows are in the set.
        public var count: Int { bits.count }
    }

    /// The shown rows `matches` holds for. **For any thread**; a long list is looked through
    /// on all cores, so `matches` must be a function of the item alone.
    public nonisolated static func rows(of basis: Basis, where matches: @Sendable (FileItem) -> Bool) -> RowSet {
        var shown: Bitset?
        if let places = basis.places {
            var bits = Bitset(size: basis.listedItems.count)
            for place in places { bits.insert(Int(place)) }
            shown = bits
        }
        return RowSet(stamp: basis.stamp, bits: ListWork.matching(basis.listedItems, among: shown, where: matches))
    }

    /// The shown rows at these indexes of `basis.items`, for a caller that worked the indexes
    /// out itself (rows that are found by comparing entries with each other, or with another
    /// list, which a test of one item cannot do). **For any thread.** Indexes outside the list
    /// are left out.
    public nonisolated static func rows(of basis: Basis, indices: some Sequence<Int>) -> RowSet {
        var bits = Bitset(size: basis.listedItems.count)
        let count = basis.items.count
        if let places = basis.places {
            for index in indices where index >= 0 && index < count { bits.insert(Int(places[index])) }
        } else {
            for index in indices where index >= 0 && index < count { bits.insert(index) }
        }
        return RowSet(stamp: basis.stamp, bits: bits)
    }

    public enum SelectionChange: Sendable {
        /// The rows become the whole selection.
        case replace
        /// The rows are marked besides what is marked.
        case add
        /// The rows lose their marks.
        case remove
    }

    /// Changes the selection by a set of rows that was worked out in the background. Returns
    /// false, and does nothing, when the list, the filter or the order have changed since the
    /// set's basis was taken: the caller works the set out again.
    @discardableResult
    public func setSelection(_ rows: RowSet, _ change: SelectionChange = .replace) -> Bool {
        guard rows.stamp == stamp, rows.bits.size == listedItems.count else { return false }
        var bits = rows.bits
        switch change {
        case .replace: break
        case .add: bits.formUnion(marks)

        case .remove:
            bits = marks
            bits.subtract(rows.bits)
        }
        setMarks(bits)
        return true
    }

    public func saveSelection() { saved = marks.isEmpty ? .none : .places(marks) }

    public func restoreSelection() {
        var bits = Bitset(size: listedItems.count)
        switch saved {
        case .none: break

        case .places(let places):
            bits = places
            if shownPlaces != nil { bits.formIntersection(shownBits()) }

        case .names(let names):
            if names.count < items.count / 4 {
                for name in names {
                    for place in places(ofExactly: name.name) where shownIndex(ofPlace: place) != nil {
                        bits.insert(place)
                    }
                }
            } else {
                for index in items.indices where names.contains(ExactName(items[index].name)) {
                    bits.insert(place(ofShown: index))
                }
            }

        case .remains(let remains, let places):
            let old = remains.lists[0]
            if places.count > Self.indexedAbove {
                // Very many names to find: all of them at once, on all cores.
                let finder = NameFinder(listedItems, index: nameIndex)
                let table = ListWork.moves(from: old, to: finder)
                nameIndex = finder.index
                places.forEach { place in
                    let to = table[place]
                    if to != .max { bits.insert(Int(to)) }
                }
                if shownPlaces != nil { bits.formIntersection(shownBits()) }
            } else {
                places.forEach { place in
                    for found in self.places(ofExactly: old[place].name) where shownIndex(ofPlace: found) != nil {
                        bits.insert(found)
                    }
                }
            }
        }
        setMarks(bits)
    }

    /// Takes the marks off the items with these names. A name written like a marked item
    /// means that item; one written differently means the marked item that reads the same.
    /// Looks every name up: **not for the main thread with many names**; a caller that
    /// knows the rows uses `setSelection(_:_:)` with `.remove`, or
    /// `setSelected(false, indices:shownVersion:)`.
    public func deselect(_ names: some Sequence<String>) {
        var left = marks
        for name in names where !left.isEmpty {
            // The other writing is looked for only when no item is written like the name.
            for place in shownPlaces(named: name) { left.remove(place) }
        }
        setMarks(left)
    }

    /// The operand rule: the selection in list order, otherwise the item under the cursor;
    /// nothing when the cursor is on `[..]`. Makes the list of the marked items (on all
    /// cores; nothing to make when everything shown is marked). **Not for the main thread on
    /// long lists** with many marks: `operandsSnapshot()` is taken here at no cost and makes
    /// the list on whatever thread asks it.
    public func operands() -> [FileItem] {
        guard !marks.isEmpty else { return cursorItem.map { [$0] } ?? [] }
        return Self.gathered(marks, of: listedItems, shown: items)
    }

    /// The marked entries in the order of the list. For any thread.
    private nonisolated static func gathered(_ marks: Bitset, of listed: [FileItem], shown: [FileItem]) -> [FileItem] {
        // Everything shown is marked: the list itself, not a copy of it.
        if marks.count == shown.count { return shown }
        guard marks.count > ListWork.pieceSize * 2 else {
            var operands: [FileItem] = []
            operands.reserveCapacity(marks.count)
            marks.forEach { operands.append(listed[$0]) }
            return operands
        }
        // A long selection is gathered on all cores.
        var places: [UInt32] = []
        places.reserveCapacity(marks.count)
        marks.forEach { places.append(UInt32($0)) }
        return ListWork.picked(listed, at: places)
    }

    /// The marks and what is shown, as they are now, in a value that can leave the main
    /// thread: taking it costs nothing (the lists are shared, the marks are a bit each), and
    /// everything it offers may be asked on any thread. For whoever needs the marked items
    /// of a long list (a drag, a command that starts a job) without holding up the main
    /// thread for making the list of them.
    public struct Operands: Sendable {
        /// What the panel shows (`PanelModel.items`).
        public let shownItems: [FileItem]
        public let cursorItem: FileItem?
        /// How many items are marked.
        public let markedCount: Int
        /// `PanelModel.shownVersion` when the value was taken.
        public let shownVersion: Int
        fileprivate let listed: [FileItem]
        fileprivate let marks: Bitset
        fileprivate let places: [UInt32]?

        /// Whether the item at an index of `shownItems` is marked.
        public func isMarked(at index: Int) -> Bool {
            shownItems.indices.contains(index) && marks.contains(places.map { Int($0[index]) } ?? index)
        }

        /// The marked items in the order of the list.
        public func markedItems() -> [FileItem] {
            marks.isEmpty ? [] : PanelModel.gathered(marks, of: listed, shown: shownItems)
        }

        /// The operand rule, as `PanelModel.operands()` has it: the marked items, otherwise
        /// the item under the cursor.
        public func items() -> [FileItem] {
            marks.isEmpty ? (cursorItem.map { [$0] } ?? []) : markedItems()
        }

        /// The indexes of the marked items in `shownItems`, rising.
        public func markedIndices() -> [Int] {
            var indices: [Int] = []
            indices.reserveCapacity(marks.count)
            guard let places else {
                marks.forEach { indices.append($0) }
                return indices
            }
            // Both rise: one walk along the shown places.
            var next = 0
            marks.forEach { place in
                while next < places.count, Int(places[next]) < place { next += 1 }
                if next < places.count, Int(places[next]) == place { indices.append(next) }
            }
            return indices
        }
    }

    public func operandsSnapshot() -> Operands {
        Operands(
            shownItems: items, cursorItem: cursorItem, markedCount: marks.count, shownVersion: stamp,
            listed: listedItems, marks: marks,
            places: shownPlaces)
    }

    /// Counts the changes of what is shown (`items`): of the list, of the filter and of the
    /// order. Indexes of `items` that were worked out in the background are good for as long
    /// as this number stays. (`listVersion` does not move with the filter.)
    public var shownVersion: Int { stamp }

    /// Marks or unmarks the items at these indexes of `items`, with no name looked up, and
    /// announces it once. Does nothing and returns false when what is shown has changed
    /// since `shownVersion` was `version`.
    @discardableResult
    public func setSelected(_ selected: Bool, indices: some Sequence<Int>, shownVersion version: Int) -> Bool {
        guard version == stamp else { return false }
        for index in indices where items.indices.contains(index) {
            let place = place(ofShown: index)
            if selected ? marks.insert(place) : marks.remove(place) { count(items[index], selected: selected) }
        }
        changed(.selection)
        return true
    }

    /// Makes the items at these indexes of `items` the whole selection. Does nothing and
    /// returns false when what is shown has changed since `shownVersion` was `version`.
    @discardableResult
    public func setSelection(indices: some Sequence<Int>, shownVersion version: Int) -> Bool {
        guard version == stamp else { return false }
        var bits = Bitset(size: listedItems.count)
        for index in indices where items.indices.contains(index) { bits.insert(place(ofShown: index)) }
        setMarks(bits)
        return true
    }

    public var hasOperands: Bool { !marks.isEmpty || cursorItem != nil }

    /// Whether the operands include a file (something that is not a folder), found without
    /// making the list of them: it stops at the first one.
    ///
    /// The answer for the marks is kept until they change, so a toolbar or a menu may ask at
    /// every tick: a long selection of nothing but folders is walked once, not every time.
    public var hasOperandFile: Bool {
        if marks.isEmpty { return cursorItem.map { !$0.isDirectory } ?? false }
        if let markedFile { return markedFile }
        let found = marks.first { !listedItems[$0].isDirectory } != nil
        markedFile = found
        return found
    }

    // MARK: Calculated sizes and totals

    public func setComputedSize(_ size: Int64, forName name: String) {
        setComputedSizes([(name: name, size: size)])
    }

    /// Sets the calculated sizes of several items, by name, and announces it once.
    public func setComputedSizes(_ sizes: [String: Int64]) {
        setComputedSizes(sizes.map { (name: $0.key, size: $0.value) })
    }

    /// The same for names as they are written: a dictionary holds only one of two names that
    /// read the same, this list holds both, and each finds its own item. The list is not
    /// another list for it (`listVersion` stays), and the time taken grows with the number
    /// of sizes, not with the length of the list, whether a filter is on or not.
    ///
    /// With one exception: while somebody else holds the list as well (a `basis` or a
    /// `snapshot` that is still alive, the listing cache, a closure that took `items`), the
    /// first size that is set makes the model's own copy of it, which for a million entries
    /// is some tens of milliseconds, once. A caller that sets sizes on such a list and must
    /// not hold up the main thread uses `prepare(_:computedSizes:)` and `apply`.
    public func setComputedSizes(_ sizes: [(name: String, size: Int64)]) {
        // Which entries are meant is settled first: looking a name up reads the lists that
        // are changed below.
        var targets: [(place: Int, size: Int64)] = []
        for (name, size) in sizes {
            let exact = places(ofExactly: name)
            if !exact.isEmpty {
                for place in exact { targets.append((place, size)) }
            } else if let shown = alike(name) {
                targets.append((place(ofShown: shown), size))
            }
        }
        guard !targets.isEmpty else { return }
        var known = sizedPlaces()
        // Without a filter both lists are one piece of memory; it is changed once and
        // shared again instead of being copied for each.
        let isShared = shownPlaces == nil
        if isShared { items = [] }
        for (place, size) in targets {
            let item = listedItems[place]
            listedItems[place].computedSize = size
            known.insert(place)
            let shown = isShared ? place : shownIndex(ofPlace: place)
            if !isShared, let shown { items[shown].computedSize = size }
            guard shown != nil, item.isFolder else { continue }
            // One folder's size moves the sums by the difference.
            let before = item.computedSize ?? 0
            let (difference, overflow) = size.subtractingReportingOverflow(before)
            if overflow || size < 0 || before < 0 {
                setListTotals(nil)
                selectedTotals = nil
            } else {
                listTotals = listTotals.flatMap { $0.adding(bytes: difference, selected: false) }
                if marks.contains(place) {
                    selectedTotals = selectedTotals.flatMap { $0.adding(bytes: difference, selected: true) }
                }
            }
        }
        if isShared { items = listedItems }
        sized = known
        sizeStamp += 1
        changed(.selection)
    }

    /// The figures of the status line (03 › Status line). A folder counts with its calculated
    /// size, once it has one. The two halves are counted when they are asked for (a long list
    /// on all cores) and kept: the totals of the list until it changes, those of the selection
    /// until it does; a single mark set or taken away is added or subtracted without counting
    /// again, and marking everything or the opposite is worked out from the list's figures.
    public var totals: Totals {
        if listTotals == nil { setListTotals(ListWork.tally(items)) }
        if selectedTotals == nil {
            let tally = marks.isEmpty ? Tally() : ListWork.tally(listedItems, at: marks)
            selectedTotals = Totals(
                selectedBytes: tally.bytes, selectedFiles: tally.files, selectedFolders: tally.folders)
        }
        let (list, selected) = (listTotals ?? Totals(), selectedTotals ?? Totals())
        return Totals(
            selectedBytes: selected.selectedBytes, totalBytes: list.totalBytes, selectedFiles: selected.selectedFiles,
            totalFiles: list.totalFiles, selectedFolders: selected.selectedFolders, totalFolders: list.totalFolders)
    }
}

/// A name as it is written: equal only to a name of the same bytes, where two `String`s are
/// equal as soon as they read the same (`é` as one character, or as `e` and an accent). What
/// the marks of a panel go by, so that of two entries whose names differ only in that, on a
/// volume that keeps both, each has its own.
struct ExactName: Hashable {
    let name: String

    init(_ name: String) {
        var name = name
        // Nearly every name is in one piece of UTF-8 already; then this does nothing.
        name.makeContiguousUTF8()
        self.name = name
    }

    nonisolated static func == (a: Self, b: Self) -> Bool { areSame(a.name, b.name) }

    func hash(into hasher: inout Hasher) {
        if name.utf8.withContiguousStorageIfAvailable({ hasher.combine(bytes: UnsafeRawBufferPointer($0)) }) == nil {
            Array(name.utf8).withUnsafeBytes { hasher.combine(bytes: $0) }
        }
    }

    /// Whether two names are the same bytes.
    nonisolated static func areSame(_ a: String, _ b: String) -> Bool {
        let same = a.utf8.withContiguousStorageIfAvailable { first in
            b.utf8.withContiguousStorageIfAvailable { second in
                first.count == second.count
                    && (first.isEmpty || memcmp(first.baseAddress!, second.baseAddress!, first.count) == 0)
            }
        }
        return (same ?? nil) ?? a.utf8.elementsEqual(b.utf8)
    }
}

/// A rule that leaves entries out of a panel's list: a display filter of the Show menu or the
/// quick filter. `matches` runs on the main thread, once per entry, and must not block; a
/// filter that is handed to `PanelModel.filtered` runs wherever that is called, on several
/// threads at once.
public struct PanelFilter: Sendable {
    /// Shown to the user while the filter is on, e.g. `*.txt`.
    public let title: String
    public let matches: @Sendable (FileItem) -> Bool

    public init(title: String, matches: @escaping @Sendable (FileItem) -> Bool) {
        self.title = title
        self.matches = matches
    }

    /// Files whose names match a file mask; folders always stay (spec 03 › Display filters).
    public nonisolated static func mask(_ text: String) -> Self {
        let mask = FileMask(text)
        return Self(title: text) { $0.isFolder || mask.matches($0.name) }
    }
}
