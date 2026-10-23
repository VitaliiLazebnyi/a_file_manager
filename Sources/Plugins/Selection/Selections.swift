import AFMContracts
import AFMKernel
import AppKit

/// The behaviour behind the Mark commands.
///
/// **Threading.** The commands run on the main thread and change the selection there. What
/// can take long is worked out elsewhere (when `background` is on): a regular expression of a
/// mask always (it can take any time), and the work on a long list, comparing two folders
/// (which asks the volumes) and the clipboard always; the lists are handed over by value and
/// the result is applied on the main thread only if the list is still the one it was made
/// for (`listVersion`). A long selection is applied in pieces, so the window stays alive.
/// Selection files touch a file system: they are written and read inside a job, on the job's
/// thread, through the file system's provider, and the job's completion returns to the main
/// thread to change the selection.
@MainActor
internal final class Selections {
    /// What Select all with the same ... compares with the item under the cursor.
    internal enum Similarity {
        /// The extension, of files only.
        case ext
        /// The name without its extension.
        case name
        /// The whole name.
        case nameAndExt
        /// The folder the entry is in.
        case path
    }

    /// A list shown only in part by this plugin.
    internal enum RestrictedView {
        /// What Mark Newer, Hide Same Files leaves of a list.
        case comparison
    }

    /// A list this plugin has cut down, and what ends that.
    internal struct Restriction {
        /// The model whose list is cut down; nil once it has gone.
        internal weak var model: PanelModel?
        /// How the list is cut down.
        internal let view: RestrictedView
        /// The directory the list was cut down in: going elsewhere ends it.
        internal let directory: URL
        /// The title of the filter, which tells whether the filter is still this plugin's.
        internal let title: String
    }

    // MARK: Changing a selection

    /// A list as work on it was started, with what tells whether it is still the list the
    /// result belongs to.
    ///
    /// Taken on the main thread (nothing is copied).
    internal struct Frozen {
        /// The model the list belongs to.
        internal let model: PanelModel
        /// The list as it was.
        internal let basis: PanelModel.Basis
        /// Guards indexes of `basis.items`.
        internal let shownVersion: Int
        /// The marked entries as they were.
        internal let operands: PanelModel.Operands

        /// The shown entries as they were.
        internal var items: [FileItem] { basis.items }

        /// Takes the list of the model as it is now.
        @MainActor
        internal init(_ model: PanelModel) {
            self.model = model
            basis = model.basis
            shownVersion = model.shownVersion
            operands = model.operandsSnapshot()
        }
    }

    /// Lists longer than this are worked on off the main thread.
    internal static let longList = 20_000
    /// How many names are applied to the model in one piece of main-thread work.
    internal static let applyPiece = 20_000

    /// How often a result that the list outgrew is worked out again before it is given up.
    internal static let attempts = 8

    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// The clipboard Load selection from clipboard reads.
    internal let pasteboard: NSPasteboard
    /// The saved masks, selection types and options.
    internal let store: SelectionStore
    /// The tabs whose lists this plugin has cut down, by the identity of their models.
    internal var restrictions: [ObjectIdentifier: Restriction] = [:]
    private var subscription: AnyObject?
    /// Whether what can take long is worked out off the main thread.
    internal let background: Bool
    /// Runs the work of `compute` off the main thread.
    private let runsWork: @Sendable (@escaping @Sendable () -> Void) -> Void
    /// The computation under way; a newer command ends it.
    private var running: CancellationFlag?

    /// The model of the source panel, which the commands work on.
    internal var source: PanelModel { kernel.panels.source.model }
    /// Where the user is asked and told things.
    internal var interaction: any UserInteraction { kernel.interaction }

    /// What Num +, Ctrl+Num + and Num * affect.
    internal var configured: SelectionScope { store.marksFolders ? .both : .files }
    /// The choice the Shift variants of Num +, Ctrl+Num + and Num * make: the one not configured.
    internal var other: SelectionScope { store.marksFolders ? .files : .both }

    /// The behaviour for the panels of `kernel`, with the clipboard `pasteboard`; with `background`,
    /// what can take long is handed to `runsWork`, which works it out elsewhere.
    internal init(
        _ kernel: Kernel,
        pasteboard: NSPasteboard,
        background: Bool,
        runsWork: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) {
        self.kernel = kernel
        self.pasteboard = pasteboard
        self.background = background
        self.runsWork = runsWork
        store = SelectionStore(settings: kernel.settings)
        // A comparison view belongs to the directory it was made in: it ends when the panel
        // goes elsewhere (spec 09 › Ending the comparison view).
        subscription = kernel.panelEvents.subscribe { [weak self] event, panel in
            if case .locationChanged = event { self?.locationChanged(of: panel.model) }
        }
    }

    /// Changes the selection of the list `frozen` was taken of by the entries at `indices`;
    /// false when the list has changed since, and nothing was done.
    internal static func take(_ indices: [Int], _ change: PanelModel.SelectionChange, in frozen: Frozen) -> Bool {
        let model = frozen.model
        switch change {
        case .replace:
            if indices.isEmpty, model.selectionCount == 0 {
                return model.shownVersion == frozen.shownVersion
            }
            return model.setSelection(indices: indices, shownVersion: frozen.shownVersion)

        case .add:
            return model.setSelected(true, indices: indices, shownVersion: frozen.shownVersion)

        case .remove:
            return model.setSelected(false, indices: indices, shownVersion: frozen.shownVersion)
        }
    }

    /// Works `work` out and then `apply`s its result on the main thread.
    ///
    /// Off the main thread when `heavy` (and background work is on), handing it a flag that ends it
    /// when a newer command has started. `apply` says whether the result still fitted the lists
    /// (the model refuses a result made for a list it no longer has): if not, and the panels still
    /// show the folders they showed, `work` is done again for the lists as they are now.
    internal func compute<Result: Sendable>(
        heavy: Bool,
        models: [PanelModel],
        _ work: @escaping @Sendable ([Frozen], CancellationFlag) -> Result,
        apply: @escaping @MainActor ([Frozen], Result) -> Bool
    ) {
        let flag = CancellationFlag()
        running?.cancel()
        running = flag
        let directories = models.map(\.directory)
        // Taken now: the result may come after the kernel has gone (a closed window, the end of a test).
        let commands = kernel.commands
        func attempt(_ number: Int) {
            let frozen = models.map(Frozen.init)
            guard heavy, background else {
                let result = work(frozen, flag)
                _ = apply(frozen, result)
                if running === flag { running = nil }
                return
            }
            // Made on the main thread and used there only: the background thread only carries them.
            let onMain = Handover((apply: apply, again: attempt))
            // (Some of this work asks a file system: on a thread of the kernel's own.)
            // `onMain` keeps this object (its `again` is a method of it) until the result is in.
            runsWork {
                let result = autoreleasepool { work(frozen, flag) }
                // A result can ask the user something (a mask that took too long): from the run loop.
                performOnMainLoop {
                    @MainActor
                    func finish() { if self.running === flag { self.running = nil } }
                    // A newer command, or a panel that went to another folder: the result is of no use.
                    guard !flag.isCancelled,
                        zip(models, directories).allSatisfy({ $0.directory.isSameLocation(as: $1) })
                    else { return finish() }
                    if onMain.value.apply(frozen, result) {
                        return finish()
                    }
                    guard number < Self.attempts else {
                        finish()
                        return commands.onRejected()
                    }
                    onMain.value.again(number + 1)
                }
            }
        }
        attempt(1)
    }

    /// Marks, unmarks or (with `.replace`) makes the selection of the shown entries that
    /// `matches` holds for.
    ///
    /// The rows are found on all cores, in the background for a long list, and the model takes them
    /// as one bit set. `matches` looks at the entry alone. `timedOut` names a mask whose regular
    /// expression may have run out of time: nothing is changed then, and the user is told.
    internal func markMatching(
        _ model: PanelModel,
        _ change: PanelModel.SelectionChange,
        timedOut mask: SelectionMask?,
        _ matches: @escaping @Sendable (FileItem) -> Bool
    ) {
        // A regular expression can take long on any list. (The result may come after the kernel
        // has gone: what tells the user is taken now.)
        let userInteraction = interaction
        compute(
            heavy: model.items.count > Self.longList || mask?.isRegex == true,
            models: [model],
            { frozen, _ in
                PanelModel.rows(of: frozen[0].basis, where: matches)
            },
            apply: { frozen, rows in
                if let mask, mask.timedOut {
                    userInteraction.inform("The regular expression takes too long.", detail: mask.text, style: .warning)
                    return true
                }
                return frozen[0].model.setSelection(rows, change)
            }
        )
    }

    /// The same for what is found by walking the whole list in order (a step, a mask that
    /// pairs files, the marks of an inversion): `find` returns indexes of the shown items.
    ///
    /// (A mask that pairs files is never a regular expression, which cannot run out of time here.).
    internal func markFound(
        _ model: PanelModel,
        _ change: PanelModel.SelectionChange,
        _ find: @escaping @Sendable ([FileItem], PanelModel.Operands, CancellationFlag) -> [Int]
    ) {
        compute(
            heavy: model.items.count > Self.longList,
            models: [model],
            { frozen, flag in
                find(frozen[0].items, frozen[0].operands, flag)
            },
            apply: { frozen, indices in
                Self.take(indices, change, in: frozen[0])
            }
        )
    }

    // MARK: Lists shown in part

    /// Whether the model's list is cut down by this plugin in that way, and still shown so.
    internal func shows(_ view: RestrictedView, in model: PanelModel) -> Bool {
        guard let restriction = restrictions[ObjectIdentifier(model)], restriction.model === model,
            restriction.view == view
        else { return false }
        // Another filter may have taken the place of this one since.
        return model.filter?.title == restriction.title
    }

    /// Shows the whole list again, if it is cut down in that way.
    internal func end(_ view: RestrictedView, in model: PanelModel) {
        guard shows(view, in: model) else {
            return
        }
        restrictions[ObjectIdentifier(model)] = nil
        model.setFilter(nil)
    }

    /// Ends the cut-down view of a model that has gone to another directory.
    private func locationChanged(of model: PanelModel) {
        guard let restriction = restrictions[ObjectIdentifier(model)], restriction.model === model,
            !restriction.directory.isSameLocation(as: model.directory)
        else { return }
        end(restriction.view, in: model)
        restrictions[ObjectIdentifier(model)] = nil
    }

    deinit {
        // Nothing to release.
    }
}
