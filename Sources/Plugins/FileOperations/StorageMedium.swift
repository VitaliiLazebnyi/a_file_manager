import Foundation
import IOKit

/// What kind of disk a local volume sits on. Several files are copied at once only where
/// that helps: a spinning disk gets slower when its head has to serve several streams.
enum StorageMedium {
    private static let lock = NSLock()
    private static var known: [String: Bool] = [:]

    /// True when `url` is a local path on a spinning disk. Anything else, and anything the
    /// system cannot tell, counts as not spinning. Safe to call from any thread; asks the
    /// system once per device.
    static func isRotational(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return false }
        let device = withUnsafePointer(to: &info.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard device.hasPrefix("/dev/") else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let answer = known[device] { return answer }
        let answer = mediumIsRotational(bsdName: String(device.dropFirst(5)))
        known[device] = answer
        return answer
    }

    /// Looks the device up in the I/O registry; the disk driver above it states its medium.
    private static func mediumIsRotational(bsdName: String) -> Bool {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let found = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, "Device Characteristics" as CFString, kCFAllocatorDefault, options)
        return ((found as? [String: Any])?["Medium Type"] as? String) == "Rotational"
    }
}
