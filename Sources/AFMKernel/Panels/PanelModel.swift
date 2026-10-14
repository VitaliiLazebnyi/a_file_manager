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
/// | `setSort(_:)` | `prepare(_:sort:)` + `apply` |
/// | `setFilter(_:narrowing:)` | `prepare(_:filter:)` + `apply` |
/// | `update(with:focus:presorted:)` | `prepare(_:update:focus:presorted:)` + `apply` |
/// | `extend(to:sortedBy:)` | `prepare(_:extendingTo:sortedBy:)` + `apply` |
/// | `setComputedSizes` on a list somebody else holds | `prepare(_:computedSizes:)` + `apply` |
/// | `select(mask:)`, `select(where:)` | `rows(of:where:)` + `setSelection(_:_:)` |
/// | `setSelected(_:names:)`, `setSelection(names:)` | the same, or `setSelected(_:indices:shownVersion:)` |
/// | `deselect(_:)` | `setSelection(_:_:)` with `.remove` |
/// | `operands()` | `operandsSnapshot()`, then `items()` on any thread |
///
/// `selectAll`, `invertSelection`, `clearSelection`, `saveSelection`, `totals` after those,
/// `hasOperandFile`, `snapshot`, `open`, `basis` and `apply` cost next to nothing at any length.
///
/// **Threading.** Everything belongs to the main thread, except the `static` functions marked
/// **for any thread** (the `prepare` functions, `rows(of:where:)`, `filtered(_:by:)`), which
/// work on a `Basis` and touch no model.
@MainActor
@preconcurrency
public final class PanelModel {
    /// How many places the visited-directories history keeps.
    nonisolated public static let historyLimit = 50
    /// Lists longer than this get their index of names made along with background work.
    nonisolated internal static let indexedAbove = 20_000

    /// Called on the main thread after every change.
    public var onChange: ((Change) -> Void)?

    /// The directory the panel shows.
    public internal(set) var directory: URL
    /// False until the directory was read for the first time; the list is empty until then.
    public internal(set) var isListed = false
    /// False while a directory is still arriving piece by piece: `items` then holds only what
    /// has come so far, and commands that mean "everything" should wait.
    public internal(set) var isComplete = true
    /// True while the list is an earlier reading of the directory, shown from memory, and a fresh
    /// one is under way (`showRemembered`).
    ///
    /// `isComplete` is false for that time as well, because the list is not known to be all there
    /// is: everything that waits for a directory to arrive waits for the fresh reading in the same
    /// way, without knowing about this.
    public internal(set) var isRefreshing = false
    /// True between `open(_:)` and the first entries: the panel is in the directory, but
    /// nothing of it has been read yet.
    public internal(set) var isOpening = false
    /// The items on screen in display order, without the `[..]` row: the directory's entries
    /// that pass the display filter.
    public internal(set) var items: [FileItem] = []
    /// Every entry of the directory in display order, shown or not.
    public internal(set) var listedItems: [FileItem] = []
    /// What is left out of the list (spec 03 › Display filters, 03 › Quick filter); nil shows
    /// everything.
    public internal(set) var filter: PanelFilter?
    /// A name the user gave the tab; nil shows the folder's name (spec 03 › Folder tabs).
    public var customTitle: String? { didSet { changed(.contents) } }
    /// A locked tab cannot be closed.
    public var isLocked = false { didSet { changed(.contents) } }
    /// Row of the cursor; row 0 is `[..]` when there is a parent row.
    ///
    /// Setting it directly is for the view that owns the cursor; commands use `moveCursor(to:)`.
    public var cursor = 0
    /// The order the list is in.
    public internal(set) var sort: ListOrder
    /// Whether the files of the list still lie in the order the file system gave them in.
    ///
    /// True for a list that was only ever shown unsorted; false from the moment it is put into the
    /// order of another key, and true again when a reading arrives while the order is `unsorted`.
    /// Sorting cannot bring that order back (`Sorter.resort`): whoever switches to `unsorted` and
    /// finds this false reads the directory again.
    public internal(set) var isInArrivalOrder = true
    /// The order the user asked for, which the list is not in yet; nil once it is.
    ///
    /// See `requestSort`.
    public internal(set) var requestedSort: ListOrder?
    /// Whether hidden files are listed, from the next reading on.
    public internal(set) var showHidden: Bool
    /// What the file system said about the directory's volume when it was read.
    public internal(set) var volume: VolumeInfo?
    /// Counts the changes of the list (`listedItems`): of its entries or of their order.
    ///
    /// Nothing else moves it: not a refresh that found the directory as it was, not a calculated
    /// folder size, not a filter. Whoever works on a copy of the list in the background notes the
    /// number first and hands the result over only if it is still the same.
    public internal(set) var listVersion = 0

    /// The marked entries, by their places in `listedItems`: always as long as that list, and
    /// never holding an entry that is not shown.
    internal var marks = Bitset() { didSet { markedFile = .unknown } }
    /// Whether a file is among the marked entries; not known until asked, and after every
    /// change of the marks (the list cannot change without them being set).
    internal var markedFile = MarkedFile.unknown
    /// What Save Selection kept.
    internal var saved = SavedMarks.nothing
    /// Which entries of `listedItems` the rows show; nil while every entry is shown, and
    /// `items` is then the very list `listedItems` is.
    internal var shownPlaces: ShownPlaces?
    /// The places whose entries have a calculated size; nil until somebody needs to know.
    internal var sized: Bitset?
    /// Counts everything a prepared change depends on: the list, the filter and the order.
    internal var stamp = 0
    /// Counts the calculated sizes that were set.
    internal var sizeStamp = 0
    /// What is kept for looking names up in the list.
    internal var lookups = NameLookups()
    /// The halves of `totals`, kept until the list or the selection changes.
    internal var counted = CountedTotals()
    /// The item the cursor should go to once it arrives, while the directory is still loading.
    internal var pendingFocus: String?
    /// The directory above; nil for a root.
    internal var parent: URL?
    /// The top of the tree the directory belongs to.
    internal var root: URL
    /// The places the panel has shown, for Go Back and Go Forward.
    internal var history: PanelHistory

    /// A tab that will show `directory` in the given order once it is read.
    public init(directory: URL, sort: ListOrder = ListOrder(), showHidden: Bool = false) {
        self.directory = directory.standardized
        self.sort = sort
        self.showHidden = showHidden
        root = self.directory
        history = PanelHistory(self.directory)
    }

    /// A second view of the same directory, as a new tab starts (spec 03 › Opening tabs).
    ///
    /// It shows what this one shows, and like this one it says whether that is all there is: a copy
    /// made while the directory is still arriving is not complete either, until whoever shows it
    /// reads the directory for it.
    public func duplicate() -> PanelModel {
        let copy = PanelModel(directory: directory, sort: sort, showHidden: showHidden)
        (copy.items, copy.listedItems, copy.shownPlaces, copy.filter, copy.cursor) = (
            items, listedItems, shownPlaces, filter, cursor
        )
        (copy.isListed, copy.isComplete, copy.isRefreshing) = (isListed, isComplete, isRefreshing)
        (copy.marks, copy.lookups.index) = (Bitset(size: listedItems.count), lookups.index)
        (copy.parent, copy.root, copy.volume, copy.isInArrivalOrder) = (parent, root, volume, isInArrivalOrder)
        return copy
    }

    /// Announces a change.
    internal func changed(_ change: Change) {
        MainThread.assert("A panel model")
        onChange?(change)
    }

    deinit {
        // A tab that is closed lets go of a long list in the background.
        Discard.later(&items)
        Discard.later(&listedItems)
    }
}
