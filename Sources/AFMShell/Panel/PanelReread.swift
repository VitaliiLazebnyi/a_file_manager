import Foundation

/// How a tab's folder is read again (`PanelViewController.reload`).
internal struct PanelReread {
    /// Asked for by the user: announced and redrawn, never put off for a reading that is under
    /// way.
    internal static let loud = Self(isQuiet: false, marksDirty: true, changedAt: nil)
    /// For a change in the folder: nothing is announced or redrawn unless the folder changed.
    internal static let quiet = Self(isQuiet: true, marksDirty: true, changedAt: nil)
    /// Quiet, and not made up for when it is turned away.
    internal static let quietOnce = Self(isQuiet: true, marksDirty: false, changedAt: nil)

    /// Nothing is announced or redrawn unless the folder changed.
    internal let isQuiet: Bool
    /// A quiet reading again that is turned away because the tab is being read or renamed, or was
    /// read a moment ago, is made up for when that is over (the folder may have changed since the
    /// reading began).
    internal let marksDirty: Bool
    /// When the change that asks for this was noticed (of the system's uptime); nil for now.
    internal let changedAt: TimeInterval?

    /// Quiet, for a change noticed at `time` (of the system's uptime).
    internal static func change(at time: TimeInterval) -> Self {
        Self(isQuiet: true, marksDirty: true, changedAt: time)
    }
}
