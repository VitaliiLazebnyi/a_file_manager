import AFMKernel
import Foundation

/// What a panel tells its surroundings (the panel coordinator), and what it asks of them.
@MainActor
internal protocol PanelHost: AnyObject {
    /// The panel got the keyboard: it is the source now.
    func panelDidBecomeActive(_ panel: PanelViewController)
    /// The panel shows another directory or another tab.
    func panelDidChangeLocation(_ panel: PanelViewController)
    /// The cursor may be on another item now, or the panel started or stopped reading.
    func panelCursorDidChange(_ panel: PanelViewController)
    /// The marked items changed.
    func panelSelectionDidChange(_ panel: PanelViewController)
    /// The panel started or stopped reading, or the folder it shows is now listed, and nothing
    /// a plugin follows has changed: the cursor is where it was, on the item it was on.
    func panelActivityDidChange(_ panel: PanelViewController)
    /// A reading of exactly this location that is already on its way (the folder under the
    /// cursor being read ahead), for the panel to take over instead of reading a second time.
    func panel(_ panel: PanelViewController, joinReadingOf location: URL, showHidden: Bool) -> ReadAhead.Joined?
    /// The places of the volume list, as far as they are known; they are asked for in the
    /// background, and `placesDidChange` tells the panel when more are known.
    func placesForVolumeList(of panel: PanelViewController) -> [Place]
    /// The drive that can be ejected (a USB stick, a disk image, a share) a location is on,
    /// from what is known of the places; nil for one that cannot be ejected.
    func ejectableVolume(containing location: URL) -> Place?
}
