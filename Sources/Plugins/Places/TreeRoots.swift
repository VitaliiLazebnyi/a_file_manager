public import AFMKernel
public import Foundation

/// Which tree a directory belongs to.
///
/// On the Mac every disk hangs below `/`, so the tree of a folder on another volume starts at that
/// volume, not at the start-up disk's root.
public enum TreeRoots {
    /// The disks among `places` and `providerRoot`, without doubles: what the tree window offers.
    public static func choices(places: [Place], providerRoot: URL) -> [Place] {
        var choices: [Place] = []
        let disks = places.filter { $0.kind == .internalDisk || $0.kind == .externalDisk || $0.kind == .home }
        for place in [Place(name: "", url: providerRoot, kind: .internalDisk)] + disks
        where !choices.contains(where: { $0.url.isSameLocation(as: place.url) }) {
            choices.append(place)
        }
        // The root's own entry from the places carries its name.
        if let named = disks.first(where: { $0.url.isSameLocation(as: providerRoot) }) {
            choices[0] = named
        }
        return choices
    }

    /// The root for the tree of `directory`: the deepest disk that holds it, else the root of
    /// its file system.
    public static func root(for directory: URL, places: [Place], providerRoot: URL) -> URL {
        let disks = places.filter { $0.kind == .internalDisk || $0.kind == .externalDisk }.map(\.url)
        let holding = disks.filter { directory.isSameLocation(as: $0) || directory.isInside($0) }
        return holding.max { $0.locationKey.count < $1.locationKey.count } ?? providerRoot
    }
}
