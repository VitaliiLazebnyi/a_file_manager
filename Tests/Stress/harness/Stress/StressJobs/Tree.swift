import Foundation

/// Making, surveying and removing the trees on disk, with every core.
internal enum Tree {
    /// Runs `body` for `0..<count`, on all cores at once.
    internal static func parallel(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
        DispatchQueue.concurrentPerform(iterations: count, execute: body)
    }

    /// The folder part of a relative path; empty for a name at the top.
    internal static func folder(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// The last part of a path.
    internal static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Makes the folder `url` and the folders above it; the harness cannot go on without it.
    internal static func createDirectory(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("cannot create \(url.path): \(error)")
        }
    }

    /// Writes the files of `entries` below `base`, with their folders.
    internal static func build(at base: URL, entries: [Entry]) {
        var folders = Set<String>()
        for entry in entries {
            folders.insert(folder(of: entry.path))
        }
        for folder in folders {
            createDirectory(base.appendingPathComponent(folder))
        }
        let chunk = 256
        parallel((entries.count + chunk - 1) / chunk) { piece in
            for position in (piece * chunk)..<min(entries.count, (piece + 1) * chunk) {
                let entry = entries[position]
                let path = base.path + "/" + entry.path
                let data = entry.content()
                let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                precondition(descriptor >= 0, "cannot create \(path)")
                data.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
                close(descriptor)
            }
        }
    }

    /// 0 missing, 1 identical, 2 different, for every entry.
    internal static func survey(_ base: URL, entries: [Entry]) -> [UInt8] {
        let chunk = 512
        let count = (entries.count + chunk - 1) / chunk
        let pieces = Shared([[UInt8]](repeating: [], count: count))
        parallel(count) { piece in
            var states: [UInt8] = []
            for position in (piece * chunk)..<min(entries.count, (piece + 1) * chunk) {
                switch Found.look(base.path, entries[position]) {
                case .missing:
                    states.append(0)

                case .identical:
                    states.append(1)

                case .different:
                    states.append(2)
                }
            }
            pieces.update { $0[piece] = states }
        }
        return pieces.value.flatMap(\.self)
    }

    /// Every path below `base` (relative), files and folders apart.
    internal static func walk(_ base: URL) -> Listing {
        var listing = Listing()
        visit(base.path, "", into: &listing)
        return listing
    }

    /// Adds what is below the folder `path` (called `relative` in the listing) to `listing`.
    private static func visit(_ path: String, _ relative: String, into listing: inout Listing) {
        guard let dir = opendir(path) else {
            return
        }
        var subfolders: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." {
                continue
            }
            let rel = relative.isEmpty ? name : relative + "/" + name
            if entry.pointee.d_type == DT_DIR {
                listing.folders.append(rel)
                subfolders.append(name)
            } else {
                listing.files.append(rel)
            }
        }
        closedir(dir)
        for name in subfolders {
            visit(path + "/" + name, relative.isEmpty ? name : relative + "/" + name, into: &listing)
        }
    }

    /// Whether `path` names one of FileJob's temporary files.
    internal static func isTemporary(_ path: String) -> Bool {
        let name = name(of: path)
        return name.hasPrefix(".afm-") && name.hasSuffix(".tmp")
    }

    /// The entries at the top of `base`, sorted by name.
    internal static func topLevel(_ base: URL) -> [URL] {
        // Every top-level entry of the trees is a folder; saying so spares a stat per name.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.sorted().map { URL(fileURLWithPath: base.path + "/" + $0, isDirectory: true) }
    }

    /// Removes `url` and everything below it, the top-level folders at the same time.
    internal static func removeQuickly(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        let children = topLevel(url)
        parallel(children.count) { try? FileManager.default.removeItem(at: children[$0]) }
        try? FileManager.default.removeItem(at: url)
    }
}
