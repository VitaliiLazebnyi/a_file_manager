import Foundation

/// The URLs of the archive file systems (spec 08 › Archives as folders).
///
/// The path of such a URL is the path of the archive file followed by the path inside the
/// archive, so everything the panels do with paths (parent, last name, "is inside") works as
/// it does on a disk, and the folder holding the archive is simply further up the same path:
///
///     zip://d3-5f0c2a91/Users/me/photos.zip/2026/beach.jpg
///
/// The host says where the archive ends: `d3` counts the path components that name the archive
/// file, the second part is a check value of that path, and for an archive that is not on the
/// local disk a third part holds, in hexadecimal, the scheme and authority of the URL it has
/// there (`ftp://server`, or the host of an outer archive: archives nest). A URL whose path
/// does not pass through the archive (the check value does not match) is a place on the
/// archive's own file system; the provider hands it on. That happens when the user types a
/// plain path while a panel is inside an archive.
internal enum ArchiveURL {
    /// What an archive URL names: a place in the archive, or one beside it.
    internal enum Place: Equatable {
        /// A place in the archive.
        case inside(ArchiveLocation)
        /// Not in the archive: a place on the file system the archive lies on.
        case outside(URL)
    }

    /// Archives whose contents can be changed (ZIP).
    internal static let writableScheme = "zip"
    /// Everything else: read-only.
    internal static let readOnlyScheme = "archive"
    /// Both schemes of the archive file systems.
    internal static let schemes = [writableScheme, readOnlyScheme]

    /// Whether the URL has one of the archive schemes.
    internal static func isArchiveURL(_ url: URL) -> Bool {
        url.scheme.map(schemes.contains) ?? false
    }

    /// The URL of `innerPath` (empty for the top folder) in the archive file `archive`, under `scheme`.
    internal static func make(scheme: String, archive: URL, innerPath: String) -> URL {
        let names = pathNames(of: archive)
        let archivePath = "/" + names.joined(separator: "/")
        var host = "d\(names.count)-" + checkValue(archivePath)
        let prefix = authority(of: archive)
        if prefix != "file://" { host += "-" + hex(prefix) }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = innerPath.isEmpty ? archivePath : archivePath + "/" + innerPath
        // Components with a scheme, a host and a path that starts with `/` always make a URL:
        // the path is escaped as it is set, and the host holds letters, digits and `-` only.
        return components.url!
    }

    /// Where an archive URL leads: inside the archive, or past it onto the archive's own file system.
    ///
    /// Nil for URLs of other schemes and for hosts this code did not write.
    internal static func parse(_ url: URL) -> Place? {
        guard isArchiveURL(url), let host = url.host else {
            return nil
        }
        let parts = host.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3, parts[0].hasPrefix("d"), let depth = Int(parts[0].dropFirst()),
            depth > 0
        else { return nil }
        let prefix: String
        if parts.count == 3 {
            guard let text = unhex(parts[2]) else {
                return nil
            }
            prefix = text
        } else {
            prefix = "file://"
        }
        let names = pathNames(of: url.standardized)
        if names.count >= depth {
            let archivePath = "/" + names[..<depth].joined(separator: "/")
            if checkValue(archivePath) == parts[1], let archive = outerURL(prefix: prefix, path: archivePath) {
                return .inside(ArchiveLocation(archive: archive, innerPath: names[depth...].joined(separator: "/")))
            }
        }
        return outerURL(prefix: prefix, path: "/" + names.joined(separator: "/")).map(Place.outside)
    }

    /// How many archives a location lies inside of: one for a place in an archive on a disk
    /// or a server, two for a place in an archive inside such an archive, and so on.
    internal static func nesting(of url: URL) -> Int {
        var (depth, current) = (0, url)
        while depth < 64, case .inside(let location)? = parse(current) {
            depth += 1
            current = location.archive
        }
        return depth
    }

    /// The location inside an archive; nil for anything else.
    internal static func location(of url: URL) -> ArchiveLocation? {
        if case .inside(let location)? = parse(url) {
            return location
        }
        return nil
    }

    /// What a URL means outside this plugin: a place that only passes through an archive
    /// scheme becomes the place on the real file system; everything else stays as it is.
    internal static func resolved(_ url: URL) -> URL {
        if case .outside(let outer)? = parse(url) {
            return outer
        }
        return url
    }

    private static func pathNames(of url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    /// Scheme and authority, e.g. `file://` or `ftp://user@server:21`.
    private static func authority(of url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        guard let text = components?.string, text.contains("://") else {
            return (url.scheme ?? "file") + "://"
        }
        return text
    }

    private static func outerURL(prefix: String, path: String) -> URL? {
        if prefix == "file://" {
            return URL(fileURLWithPath: path, isDirectory: false)
        }
        guard var components = URLComponents(string: prefix) else {
            return nil
        }
        components.path = path
        return components.url
    }

    /// FNV-1a over the archive's path: enough to tell "this path runs through the archive"
    /// from "this path is somewhere else".
    private static func checkValue(_ path: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(format: "%08x", hash)
    }

    private static func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func unhex(_ text: String) -> String? {
        guard text.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
