import AFMContracts
public import AFMKernel
import AppKit
import Foundation

/// Compare by content (spec 09 › Compare by content).
///
/// The command takes its two files from the panels by the rules of the spec. Other plugins
/// (Synchronize directories, an overwrite question) name the files themselves: a `.text`
/// argument holds the two locations on two lines, each a URL or a path as the user would type
/// it, and either line may be empty; a `.location` argument names the first file only. With
/// fewer than two files the window opens for the user to choose.
public final class CompareContentPlugin: Plugin {
    /// The plugin's name in the kernel's list of plugins.
    public let name = "CompareContent"
    private let opensWindows: Bool
    private let effects: CompareWindowEffects
    /// The sessions of the open windows; without windows (tests), the last one started.
    internal private(set) var sessions: [CompareSession] = []
    /// The open windows.
    internal private(set) var windows: [CompareWindowController] = []
    private weak var owner: Kernel?

    /// Tests pass `opensWindows: false` and look at the session; the work then runs on the
    /// calling thread.
    public convenience init(opensWindows: Bool = true) {
        self.init(opensWindows: opensWindows, effects: .system)
    }

    /// Windows whose beeps, file panel, font panel and clipboard are `effects`.
    internal init(opensWindows: Bool, effects: CompareWindowEffects) {
        self.opensWindows = opensWindows
        self.effects = effects
    }

    /// The page of the plugin's settings in the preferences window.
    private static func preferencePage() -> PreferencePage {
        func key(_ name: String) -> String { CompareSettingsKey.scope + "." + name }
        return
            PreferencePage(
                title: "Compare by content",
                preferences: [
                    Preference(
                        key(CompareSettingsKey.ignoreCase),
                        "Ignore upper and lower case",
                        .flag(default: true)
                    ),
                    Preference(key(CompareSettingsKey.ignoreSpaces), "Ignore repeated spaces", .flag(default: true)),
                    Preference(
                        key(CompareSettingsKey.ignoreLineEndings),
                        "Ignore line-end differences",
                        .flag(default: true)
                    ),
                    Preference(
                        key(CompareSettingsKey.vertical),
                        "Show the two files above each other",
                        .flag(default: false)
                    ),
                    Preference(
                        key(CompareSettingsKey.bytesPerLine),
                        "Bytes per line in binary mode",
                        .choice(CompareSettingsKey.bytesPerLineChoices.map(String.init), default: 1)
                    )
                ]
            )
    }

    /// Registers the command with its menu items, toolbar button and preference page.
    ///
    /// Called once on the main thread when the kernel loads the plugin.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        self.owner = owner
        kernel.commands.register(
            Command(.compareByContent, "Compare By Content…", runsDuringJobs: true)
        ) { [self] argument in
            let panels = kernel.panels
            let files =
                CompareOperands.parse(
                    argument,
                    fileSystems: kernel.fileSystems,
                    base: panels.source.model.directory
                )
                ?? CompareOperands.choose(source: panels.source.model, target: panels.target.model)
            open(files, in: kernel)
        }
        kernel.menus.add([.compareByContent], to: .filesAdvanced)
        kernel.menus.addToContextMenu([.compareByContent], in: .tools, onItemOnly: true)
        kernel.toolbar.add(
            .compareByContent,
            symbol: "arrow.left.arrow.right.square",
            group: 50,
            hint: "Compare two files and show the differences side by side."
        )
        kernel.preferences.add(Self.preferencePage())
    }

    /// Compares `files` in a new session: in a window, or (tests) inline on the calling thread.
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
        let controller = CompareWindowController(session: session, effects: effects) { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            self?.sessions.removeAll { $0 === session }
        }
        windows.append(controller)
        session.compare { [weak controller, weak session] hasContent in
            guard let controller, let session else {
                return
            }
            if !(hasContent && !session.isIdentical || files.left == nil || files.right == nil) { controller.close() }
        }
        controller.show()
    }

    /// Asks about every window with edits that are not saved, before the program quits: Save,
    /// Don't Save or Cancel.
    ///
    /// False when the user cancels (or a save fails), so that the quit can be called off. The shell
    /// consults this where it can; `stop` asks once more for what is left.
    public func shouldTerminate() -> Bool {
        askAboutUnsavedChanges(allowCancel: true)
    }

    /// Asks about each session with unsaved edits; false when the user cancels or a save fails.
    private func askAboutUnsavedChanges(allowCancel: Bool) -> Bool {
        guard let kernel = owner else {
            return true
        }
        for session in sessions where session.hasUnsavedChanges {
            let names = [
                session.modified.left ? session.displayPath(.left) : nil,
                session.modified.right ? session.displayPath(.right) : nil
            ]
            .compactMap(\.self)
            .joined(separator: "\n")
            let buttons = [("Save", 0), ("Don't Save", 1)] + (allowCancel ? [("Cancel", 2)] : [])
            let answer = kernel.interaction.pick(
                "Save the changes?",
                detail: "The compared files were edited:\n" + names,
                buttons,
                fallback: allowCancel ? 2 : 0,
                style: .warning
            )
            switch answer {
            case 0:
                if !session.saveNow(), allowCancel {
                    return false
                }

            case 1:
                session.discardChanges()

            default:
                return false
            }
        }
        return true
    }

    /// Offers to save what is still unsaved, then cancels every session and closes every window.
    ///
    /// Called on the main thread when the program quits.
    public func stop() {
        // Quitting with edits that were not asked about (nothing can be called off any more): the last chance to
        // save them.
        _ = askAboutUnsavedChanges(allowCancel: false)
        for session in sessions {
            session.cancel()
        }
        for window in windows {
            window.close()
        }
    }
}
