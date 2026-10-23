import Foundation

/// The commands that look at or change single items: sizes, times, modes, deleting, renaming.
extension TestFTPSession {
    /// MLST: the facts of one item, in an MLSD line.
    internal func listOne(_ path: String) {
        guard server.options.offersMLSD else {
            reply("500 Unknown command")
            return
        }
        guard let url = local(path), fileManager.fileExists(atPath: url.path) else {
            reply("550 Not found")
            return
        }
        reply("250-Listing\r\n \(line(for: url, name: virtual(url), style: .machine))\r\n250 End")
    }

    /// SIZE: the size of a file in bytes.
    internal func reportSize(_ path: String) {
        guard server.options.offersSize else {
            reply("500 Unknown command")
            return
        }
        guard let url = local(path), fileManager.fileExists(atPath: url.path), !isDirectory(url) else {
            reply("550 Not a file")
            return
        }
        reply("213 \(size(of: url))")
    }

    /// MDTM: when a file was last changed, as `yyyyMMddHHmmss` in UTC.
    internal func modificationTime(_ path: String) {
        guard let url = local(path), fileManager.fileExists(atPath: url.path), !isDirectory(url) else {
            reply("550 Not a file")
            return
        }
        reply("213 \(stamp(modified(url)))")
    }

    /// MFMT: sets when an item was last changed (`MFMT yyyyMMddHHmmss path`).
    internal func setModificationTime(_ argument: String) {
        let parts = argument.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let url = local(String(parts[1])),
            let date = Self.stampFormat.date(from: String(parts[0]))
        else {
            reply("501 Bad arguments")
            return
        }
        try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        reply("213 Modify=\(parts[0]); \(parts[1])")
    }

    /// SITE: only `SITE CHMOD <octal mode> path`.
    internal func site(_ argument: String) {
        let parts = argument.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, parts[0].uppercased() == "CHMOD", let mode = Int(parts[1], radix: 8),
            let url = local(String(parts[2]))
        else {
            reply("500 Unknown SITE command")
            return
        }
        try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        reply("200 CHMOD OK")
    }

    /// DELE: deletes a file, unless the options refuse it.
    internal func delete(_ path: String) {
        guard let url = local(path), fileManager.fileExists(atPath: url.path), !isDirectory(url) else {
            reply("550 No such file")
            return
        }
        if server.options.refusesDelete {
            reply("550 Permission denied")
            return
        }
        reply((try? fileManager.removeItem(at: url)) != nil ? "250 Deleted" : "550 Cannot delete")
    }

    /// RMD: removes an empty folder.
    internal func removeDirectory(_ path: String) {
        guard let url = local(path), isDirectory(url) else {
            reply("550 Not a directory")
            return
        }
        reply(rmdir(url.path) == 0 ? "250 Removed" : "550 Directory not empty")
    }

    /// MKD: makes a folder where nothing is.
    internal func makeDirectory(_ path: String) {
        guard let url = local(path), !fileManager.fileExists(atPath: url.path) else {
            reply("550 Already exists")
            return
        }
        reply(
            (try? fileManager.createDirectory(at: url, withIntermediateDirectories: false)) != nil
                ? "257 \"\(virtual(url))\" created" : "550 Cannot create"
        )
    }

    /// RNFR: notes what the next RNTO renames.
    internal func renameFrom(_ path: String) {
        guard let url = local(path), fileManager.fileExists(atPath: url.path) else {
            reply("550 No such file")
            return
        }
        renameSource = url.path
        reply("350 Ready for RNTO")
    }

    /// RNTO: renames what RNFR named, the way `rename(2)` does unless the options refuse it.
    internal func renameTo(_ path: String) {
        guard let from = renameSource, let url = local(path) else {
            reply("503 RNFR first")
            return
        }
        let options = server.options
        renameSource = nil
        if let refused = options.refusesRenameOf, refused == "*" || from.hasSuffix(refused) {
            reply("550 Permission denied")
            return
        }
        if options.renameKeepsExisting, fileManager.fileExists(atPath: url.path) {
            reply("550 File exists")
            return
        }
        reply(rename(from, url.path) == 0 ? "250 Renamed" : "550 Cannot rename")
    }
}
