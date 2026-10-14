import AFMContracts
public import AFMKernel
public import AppKit

/// The Multi-Rename Tool (spec 09 › Multi-Rename Tool).
public final class MultiRenamePlugin: Plugin {
    public let name = "MultiRename"
    private let opensWindows: Bool
    private let logDirectory: URL?
    private var window: MultiRenameWindowController?
    /// The tool's state while it is open; without windows (tests) it is driven directly.
    private(set) var session: MultiRenameSession?
    /// The settings last used in this run of the program; they are not kept beyond it.
    private var lastSettings: RenameSettings?
    private var store: RenameStore?

    /// `opensWindows` false keeps the tool windowless, for tests, and computes previews at
    /// once. `logDirectory` is where the result log goes; by default a folder of the program
    /// in the temporary directory.
    public init(opensWindows: Bool = true, logDirectory: URL? = nil) {
        self.opensWindows = opensWindows
        self.logDirectory = logDirectory
    }

    public func start(in kernel: Kernel) {
        let source = { kernel.panels.source.model }
        let isWritable = { kernel.fileSystems.capabilities(for: source().directory).contains(.write) }
        // `.text`: the name of saved settings to open the tool with (the spec's `MULTIRENAME <name>`).
        kernel.commands.register(
            Command(.multiRename, "Multi-Rename Tool…", [Shortcut(.character("m"), .control)]),
            enabled: { source().hasOperands && isWritable() },
            parameterized: { [self] argument in
                open(kernel, settingsName: argument.text)
            })
        kernel.menus.add([.multiRename], to: .filesAdvanced)
        kernel.menus.addToContextMenu([.multiRename], in: .tools, onItemOnly: true)
        kernel.toolbar.add(
            .multiRename, symbol: "character.cursor.ibeam", group: 50,
            hint: "Rename many files at once, with a pattern, counters and search and replace.")
        kernel.preferences.add(
            PreferencePage(
                title: "Multi-Rename Tool",
                preferences: [
                    Preference(
                        RenameStore.undoLimitKey, "Rename runs that can be undone (0 = no Undo)", .text(default: "20")
                    ),
                    Preference(
                        RenameStore.startupSettingsKey, "Saved settings to open the tool with (empty = last used)",
                        .text(default: "")),
                    Preference(
                        RenameStore.lowercaseWordsKey, "Words kept in lower case in titles",
                        .text(default: TitleCaseRule.defaultSetting))
                ]))
    }

    private func open(_ kernel: Kernel, settingsName: String?) {
        let items = kernel.panels.source.model.operands()
        guard !items.isEmpty else { return }
        let store = RenameStore(settings: kernel.settings)
        self.store = store
        lastSettings = session?.settings ?? lastSettings
        session?.close()
        // A name that is not known gives the defaults.
        let wanted = settingsName ?? (store.startupSettingsName.isEmpty ? nil : store.startupSettingsName)
        let settings = wanted.map { store.saved[$0] ?? .unchanged } ?? lastSettings ?? .unchanged
        // The log of a run is kept in the user's own Logs folder, not in the temporary one.
        let product = kernel.productName.replacingOccurrences(of: "/", with: "_")
        let log =
            logDirectory
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent(
                "Logs"
            ).appendingPathComponent(product)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(product)
        // Asked for from a queue of the session, which waits; read on the main thread, as
        // `NSPasteboard` is not made for other threads.
        var clipboard: @Sendable () -> String? = { nil }
        var changeCount: (@MainActor () -> Int)?
        if opensWindows {
            clipboard = { kernel.askUser { _ in NSPasteboard.general.string(forType: .string) } }
            changeCount = { NSPasteboard.general.changeCount }
        }
        let session = MultiRenameSession(
            kernel: kernel, items: items, store: store, settings: settings, logDirectory: log,
            previewsInBackground: opensWindows, clipboard: clipboard, clipboardChangeCount: changeCount)
        self.session = session
        guard opensWindows else { return }
        // The tool that is open is closed first, and its closing is not told to anyone: it
        // would find the new session and let go of it.
        if let old = window {
            window = nil
            old.onClose = nil
            old.close()
        }
        let controller = MultiRenameWindowController(kernel: kernel, session: session)
        window = controller
        // A closed tool lets go of its window and session (a running job holds on to the
        // session itself); the settings last used are kept for the next time.
        controller.onClose = { [weak self, weak controller] in
            guard let self, window === controller else { return }
            lastSettings = self.session?.settings ?? lastSettings
            window = nil
            self.session = nil
        }
        controller.showWindow(nil)
    }

    public func stop() {
        window?.close()
        store?.flush()
    }
}
