import Foundation

/// What happens when the user opens a file (Enter, double click). Plugins offer openers; the
/// first one that takes the file wins. An archive plugin enters a `.zip` as a folder this way,
/// ahead of the plugin that hands files to their applications.
public final class OpenerRegistry {
    /// Returns true when it took care of the file.
    public typealias Opener = (_ file: FileItem, _ panel: PanelHandle) -> Bool

    private var openers: [(priority: Int, open: Opener)] = []

    public init() {}

    /// Openers are tried from the highest priority down; among equals, in the order added.
    /// Use 0 for a general opener and a higher number for one that is picky about its files.
    public func add(priority: Int = 0, _ opener: @escaping Opener) {
        let index = openers.firstIndex { $0.priority < priority } ?? openers.count
        openers.insert((priority, opener), at: index)
    }

    /// False when no plugin opens this file.
    @discardableResult
    public func open(_ file: FileItem, in panel: PanelHandle) -> Bool {
        openers.contains { $0.open(file, panel) }
    }
}
