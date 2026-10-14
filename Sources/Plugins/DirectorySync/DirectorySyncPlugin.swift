import AFMContracts
public import AFMKernel
import AppKit
import Foundation

/// Synchronize directories (spec 09 › Synchronize directories).
///
/// The command opens a window preset with the directories of the two panels. Called with a
/// `.text` argument it loads the saved set of that name first, and with `=name` it also
/// compares at once (the spec's `SYNCOPEN`).
public final class DirectorySyncPlugin: Plugin {
    public let name = "DirectorySync"
    private let opensWindows: Bool
    /// The state behind the window; it exists from the first time the command runs.
    private(set) var session: SyncSession?
    private var window: SyncWindowController?

    /// Tests pass `opensWindows: false` and drive the session directly; comparisons then run
    /// on the calling thread.
    public init(opensWindows: Bool = true) {
        self.opensWindows = opensWindows
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        kernel.commands.register(
            Command(.synchronizeDirectories, "Synchronize Dirs…", runsDuringJobs: true),
            parameterized: { [self] argument in
                open(in: kernel, set: argument.text)
            }
        )
        kernel.menus.add([.synchronizeDirectories], to: .commandsTools)
        kernel.toolbar.add(
            .synchronizeDirectories,
            symbol: "arrow.triangle.2.circlepath",
            group: 50,
            hint: "Compare two folders, including subfolders, and copy what differs to make them the same."
        )

        func key(_ name: String) -> String { SyncSettingsKey.scope + "." + name }
        kernel.preferences.add(
            PreferencePage(
                title: "Synchronize directories",
                preferences: [
                    Preference(
                        key(SyncSettingsKey.recompare),
                        "Compare again after synchronizing",
                        .flag(default: true)
                    ),
                    Preference(
                        key(SyncSettingsKey.confirmOverwrites),
                        "Confirm overwrites (default of the Synchronize dialog)",
                        .flag(default: true)
                    ),
                    Preference(
                        key(SyncSettingsKey.useTrash),
                        "Move deleted files to the Trash where possible",
                        .flag(default: true)
                    ),
                    Preference(
                        key(SyncSettingsKey.changeSourceDates),
                        "When a target cannot keep a file's date, give the source file the target's date",
                        .flag(default: true)
                    ),
                    Preference(
                        key(SyncSettingsKey.warnReadErrors),
                        "Report directories that could not be read",
                        .flag(default: true)
                    )
                ]
            )
        )
    }

    private func open(in kernel: Kernel, set: String?) {
        let session = self.session ?? SyncSession(kernel: kernel)
        self.session = session
        session.runsInline = !opensWindows
        let panels = kernel.panels
        session.adopt(
            left: panels.left.model,
            right: panels.right.model,
            includeHidden: panels.source.model.showHidden
        )
        var compareAtOnce = false
        if var name = set {
            compareAtOnce = name.hasPrefix("=")
            if compareAtOnce { name.removeFirst() }
            if !name.isEmpty, !session.loadSet(named: name) {
                kernel.interaction.inform("There are no saved synchronize settings named \(name).")
            }
        }
        if opensWindows {
            let controller = window ?? SyncWindowController(session: session)
            window = controller
            controller.show()
        }
        if compareAtOnce { session.compare() }
    }

    public func stop() {
        session?.cancelComparison()
        window?.close()
    }
}
