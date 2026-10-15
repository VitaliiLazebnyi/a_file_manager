import AFMKernel
import Foundation

@testable import AFMShell

/// Surroundings of a panel that answer as the test says and keep what the panel told them.
@MainActor
internal final class PanelFakeHost: PanelHost {
    /// The places of the volume list.
    internal var places: [Place] = []
    /// The drive that can be ejected, wherever the panel is.
    internal var ejectable: Place?
    /// A reading ahead the panel may take over, for any location.
    internal var joinable: ReadAhead.Joined?
    /// What the panel told, in order.
    internal private(set) var told: [String] = []

    /// Kept.
    internal func panelDidBecomeActive(_: PanelViewController) {
        told.append("active")
    }

    /// Kept.
    internal func panelDidChangeLocation(_: PanelViewController) {
        told.append("location")
    }

    /// Kept.
    internal func panelCursorDidChange(_: PanelViewController) {
        told.append("cursor")
    }

    /// Kept.
    internal func panelSelectionDidChange(_: PanelViewController) {
        told.append("selection")
    }

    /// Kept.
    internal func panelActivityDidChange(_: PanelViewController) {
        told.append("activity")
    }

    /// `joinable`, once: a reading that was taken over is gone.
    internal func panel(_: PanelViewController, joinReadingOf _: URL, showHidden _: Bool) -> ReadAhead.Joined? {
        defer { joinable = nil }
        return joinable
    }

    /// `places`.
    internal func placesForVolumeList(of _: PanelViewController) -> [Place] {
        places
    }

    /// `ejectable`.
    internal func ejectableVolume(containing _: URL) -> Place? {
        ejectable
    }

    deinit {
        // Nothing to release.
    }
}
