import AFMContracts
import AFMKernel
import Foundation

/// Compare by content (spec 09 › Compare by content).
///
/// The command takes its two files from the panels by the rules of the spec. Other plugins
/// (Synchronize directories, an overwrite question) name the files themselves: a `.text`
/// argument holds the two locations on two lines, each a URL or a path as the user would type
/// it, and either line may be empty; a `.location` argument names the first file only. With
/// fewer than two files the window opens for the user to choose.
public final class CompareContentPlugin: Plugin {
    public let name = "CompareContent"
    private let opensWindows: Bool
    /// The sessions of the open windows; without windows (tests), the last one started.
    private(set) var sessions: [CompareSession] = []
    private var windows: [CompareWindowController] = []
    private weak var kernel: Kernel?

    /// Tests pass `opensWindows: false` and look at the session; the work then runs on the
    /// calling thread.
    public init(opensWindows: Bool = true) {
        self.opensWindows = opensWindows
    }

    public func start(in kernel: Kernel) {
        self.kernel = kernel
        kernel.commands.register(Command(.compareByContent, "Compare By Content…", runsDuringJobs: true), parameterized: { [self] argument in
            let panels = kernel.panels
            let files = CompareOperands.parse(argument, fileSystems: kernel.fileSystems, base: panels.source.model.directory)
                ?? CompareOperands.choose(source: panels.source.model, target: panels.target.model)
            open(files, in: kernel)
        })
        kernel.menus.add([.compareByContent], to: .filesAdvanced)
        kernel.menus.addToContextMenu([.compareByContent], in: .tools, onItemOnly: true)
        kernel.toolbar.add(.compareByContent, symbol: "arrow.left.arrow.right.square", group: 50, hint: "Compare two files and show the differences side by side.")

        func key(_ name: String) -> String { CompareSettingsKey.scope + "." + name }
        kernel.preferences.add(PreferencePage(title: "Compare by content", preferences: [
            Preference(key(CompareSettingsKey.ignoreCase), "Ignore upper and lower case", .flag(default: true)),
            Preference(key(CompareSettingsKey.ignoreSpaces), "Ignore repeated spaces", .flag(default: true)),
            Preference(key(CompareSettingsKey.ignoreLineEndings), "Ignore line-end differences", .flag(default: true)),
            Preference(key(CompareSettingsKey.vertical), "Show the two files above each other", .flag(default: false)),
            Preference(key(CompareSettingsKey.bytesPerLine), "Bytes per line in binary mode",
                       .choice(CompareSettingsKey.bytesPerLineChoices.map(String.init), default: 1)),
        ]))
    }

    private func open(_ files: (left: URL?, right: URL?), in kernel: Kernel) {
        let session = CompareSession(kernel: kernel)
        session.runsInline = !opensWindows
        session.leftURL = files.left
        session.rightURL = files.right
        guard opensWindows else {
            sessions = [session]
            session.compare()
            return
        }
        sessions.append(session)
        // The window opens at once, so that loading two large files shows progress and can be
        // cancelled with Esc. Identical files only get the message, and so do files that
        // cannot be read (spec 09 › Opening and choosing the files): the window closes again.
        let controller = CompareWindowController(session: session) { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            self?.sessions.removeAll { $0 === session }
        }
        windows.append(controller)
        session.compare { [weak controller, weak session] hasContent in
            guard let controller, let session else { return }
            if !(hasContent && !session.isIdentical || files.left == nil || files.right == nil) { controller.close() }
        }
        controller.show()
    }

    /// Asks about every window with edits that are not saved, before the program quits: Save,
    /// Don't Save or Cancel. False when the user cancels (or a save fails), so that the quit can be
    /// called off. The shell consults this where it can; `stop` asks once more for what is left.
    public func shouldTerminate() -> Bool {
        askAboutUnsavedChanges(allowCancel: true)
    }

    private func askAboutUnsavedChanges(allowCancel: Bool) -> Bool {
        guard let kernel else { return true }
        for session in sessions where session.hasUnsavedChanges {
            let names = [session.modified.left ? session.displayPath(.left) : nil, session.modified.right ? session.displayPath(.right) : nil]
                .compactMap { $0 }.joined(separator: "\n")
            let buttons = [("Save", 0), ("Don't Save", 1)] + (allowCancel ? [("Cancel", 2)] : [])
            switch kernel.ui.pick("Save the changes?", detail: "The compared files were edited:\n" + names, buttons, fallback: allowCancel ? 2 : 0, style: .warning) {
            case 0: if !session.saveNow() && allowCancel { return false }
            case 1: session.discardChanges()
            default: return false
            }
        }
        return true
    }

    public func stop() {
        // Quitting with edits that were not asked about (nothing can be called off any more): the last chance to save them.
        _ = askAboutUnsavedChanges(allowCancel: false)
        sessions.forEach { $0.cancel() }
        windows.forEach { $0.close() }
    }
}

/// Which two files the command compares (spec 09 › Opening and choosing the files).
enum CompareOperands {
    /// Two selected files of the source panel; or its one selected file with the first selected
    /// file of the target panel, else with the file of the same name there; or, with nothing
    /// selected, the file under the cursor with the file of the same name in the target panel.
    /// The target panel's cursor is never used. Works on what the panels list.
    static func choose(source: PanelModel, target: PanelModel) -> (left: URL?, right: URL?) {
        /// The first `limit` marked files in list order. Nothing marked is known at once, and the walk over the
        /// marks (a bit each) stops at the limit, so a selection of 300,000 does not cost a pass over them.
        func selectedFiles(_ model: PanelModel, limit: Int) -> [FileItem] {
            guard model.selectionCount > 0 else { return [] }
            let snapshot = model.operandsSnapshot()
            var found: [FileItem] = []
            for index in snapshot.shownItems.indices where snapshot.isMarked(at: index) && !snapshot.shownItems[index].isDirectory {
                found.append(snapshot.shownItems[index])
                if found.count == limit { break }
            }
            return found
        }
        func sameName(as file: FileItem) -> URL? {
            guard !target.directory.isSameLocation(as: source.directory), let row = target.row(ofName: file.name),
                  let match = target.item(atRow: row), !match.isDirectory, match.name == file.name else { return nil }
            return match.url
        }
        let selected = selectedFiles(source, limit: 2)
        if selected.count >= 2 { return (selected[0].url, selected[1].url) }
        if let only = selected.first { return (only.url, selectedFiles(target, limit: 1).first?.url ?? sameName(as: only)) }
        guard let cursor = source.cursorItem, !cursor.isDirectory else { return (nil, nil) }
        return (cursor.url, sameName(as: cursor))
    }

    /// The files another plugin named; nil when the argument names none.
    static func parse(_ argument: CommandArgument, fileSystems: FileSystemRegistry, base: URL) -> (left: URL?, right: URL?)? {
        if let location = argument.location { return (location, nil) }
        guard let text = argument.text else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        func location(_ line: String?) -> URL? {
            guard let line, !line.isEmpty else { return nil }
            if let url = URL(string: line), let scheme = url.scheme, (try? fileSystems.provider(for: url)) != nil, scheme.count > 1 { return url }
            return fileSystems.location(from: line, relativeTo: base)
        }
        return (location(lines.first), location(lines.count > 1 ? lines[1] : nil))
    }
}
