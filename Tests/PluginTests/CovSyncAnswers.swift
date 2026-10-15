import AppKit

@testable import DirectorySyncPlugin

/// What the Synchronize directories window is told outside itself, and how often it asked.
@MainActor
internal final class CovSyncAnswers {
    /// The folder the panel answers with.
    internal var folder: URL?
    /// How often the folder panel was asked for.
    internal private(set) var folderRequests = 0
    /// How often the sets pop-up was opened.
    internal private(set) var menusShown = 0

    /// Effects that answer from here.
    internal var effects: SyncWindowEffects {
        SyncWindowEffects(
            chooseFolder: { [weak self] _, chosen in
                self?.folderRequests += 1
                chosen(self?.folder)
            },
            showMenu: { [weak self] _ in self?.menusShown += 1 }
        )
    }

    deinit {
        // Nothing to release.
    }
}
