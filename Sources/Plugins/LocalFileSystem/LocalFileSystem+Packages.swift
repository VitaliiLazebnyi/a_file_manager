import Foundation

/// Telling the folders that are shown as files (packages) from plain ones.
extension LocalFileSystem {
    /// The Finder's bundle bit among the flags of a folder's Finder information.
    private static let bundleFlag: UInt16 = 0x2000

    /// Whether Finder flags have the bundle bit set.
    private static func hasBundleBit(_ flags: UInt16) -> Bool { flags & bundleFlag != 0 }

    /// The flags of the Finder information of a folder; nil when they cannot be read.
    private static func finderFlags(_ path: String) -> UInt16? {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_FNDRINFO)
        // The answer: its length, then the 32 bytes of Finder information. For a folder the
        // flags are the two bytes after the window rectangle, high byte first.
        var reply = [UInt8](repeating: 0, count: 36)
        guard getattrlist(path, &request, &reply, reply.count, UInt32(FSOPT_NOFOLLOW)) == 0 else {
            return nil
        }
        return UInt16(reply[12]) << 8 | UInt16(reply[13])
    }

    /// A folder that is shown and opened like a file (`.app` and the like).
    ///
    /// Only folders with an extension can be one, so plain folders cost nothing. The system decides
    /// by the extension, or by a mark on the folder itself (its bundle bit). Asking it is slow, so
    /// what it said about an extension is remembered for a while and only the mark, which is quick
    /// to read, is looked up for each folder.
    internal func isPackage(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension
        guard !pathExtension.isEmpty else {
            return false
        }
        // A folder that is a share's mount point is not asked: the share may not answer.
        guard MountTable.shared.isLocal(url.path) else {
            return false
        }
        let key = pathExtension.lowercased()
        func askSystem() -> URLResourceValues? { try? url.resourceValues(forKeys: [.isPackageKey]) }
        packageLock.lock()
        let known = packageExtensions[key]
            .flatMap { learned in
                DispatchTime.now().uptimeNanoseconds - learned.learned < 60_000_000_000 ? learned.isPackage : nil
            }
        packageLock.unlock()
        if known == true {
            return true
        }
        if known == false {
            // Not a package by its extension; the mark can still make it one.
            return Self.finderFlags(url.path).map(Self.hasBundleBit) ?? askSystem()?.isPackage ?? false
        }
        guard let answer = askSystem()?.isPackage else {
            return false
        }
        // The answer speaks for the extension unless the folder's own mark gave it.
        if !answer || Self.finderFlags(url.path).map(Self.hasBundleBit) == false {
            packageLock.lock()
            if packageExtensions.count > 4_096 { packageExtensions.removeAll() }
            packageExtensions[key] = (answer, DispatchTime.now().uptimeNanoseconds)
            packageLock.unlock()
        }
        return answer
    }
}
