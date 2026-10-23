import AFMKernel
import Foundation

/// Create checksums: the files hashed, grouped into their checksum files, and the files written.
extension ChecksumRun {
    /// Hashes the files and writes the checksum file(s).
    ///
    /// `target` is the checksum file for all, or, with separate files, the folder and pattern for
    /// them. Returns what was written.
    internal static func create(for operands: [FileItem], target: URL, options: CreateOptions, run: ToolRun) throws
        -> [URL]
    {
        var files = try files(below: operands, run: run)
        // A checksum file among the operands is about to be replaced: it is not hashed, or the
        // new one would list itself with a stale digest.
        let outputs = Set(files.map { file in outputURL(for: file, target: target, options: options).locationKey })
        files.removeAll { file in outputs.contains(file.url.locationKey) }
        guard !files.isEmpty else {
            throw ToolError.failed("No files selected!")
        }
        run.expect(bytes: files.reduce(0) { total, file in total.addingSaturated(file.size) }, items: files.count)
        run.show(["Creating \(options.method.title) checksums"])
        let entries = try hashed(files, method: options.method, run: run)
        let groups = try checksumFiles(of: entries, target: target, options: options)
        return try write(groups, options: options, run: run)
    }

    /// Each file with its digest; throws when one could not be read, for a checksum file that silently lacks
    /// files would mislead.
    private static func hashed(_ files: [FileItem], method: ChecksumMethod, run: ToolRun) throws -> [(
        file: FileItem, digest: [UInt8]
    )] {
        let digests = digests(of: files.map { file in (file.url, [method]) }, run: run)
        try run.checkCancelled()
        var entries: [(file: FileItem, digest: [UInt8])] = []
        for (file, result) in zip(files, digests) {
            switch result {
            case .success(let found):
                entries.append((file, found[0]))

            case .failure(let error):
                throw ToolError.failed("\(file.name): \(error.localizedDescription)")
            }
        }
        return entries
    }

    /// The checksum files to write, in order, each with its entries; throws where the names would not read
    /// back as the files they stand for.
    private static func checksumFiles(
        of entries: [(file: FileItem, digest: [UInt8])],
        target: URL,
        options: CreateOptions
    ) throws -> [(url: URL, entries: [(name: String, digest: [UInt8])])] {
        var groups: [(url: URL, entries: [(name: String, digest: [UInt8])])] = []
        var groupIndex: [String: Int] = [:]
        for entry in entries {
            let url = outputURL(for: entry.file, target: target, options: options)
            // Names are relative to the checksum file's folder; files elsewhere keep their full path.
            var name = Self.name(of: entry.file.url, in: url.deletingLastPathComponent())
            if options.separatePerFolder || (options.separatePerFile && name.hasPrefix("/")) {
                name = entry.file.name
            }
            if let index = groupIndex[url.locationKey] {
                groups[index].entries.append((name, entry.digest))
            } else {
                groupIndex[url.locationKey] = groups.count
                groups.append((url, [(name, entry.digest)]))
            }
        }
        // Several files that would share one checksum file under one name cannot be told apart in it.
        if options.separatePerFile,
            groups.contains(where: { group in Set(group.entries.map(\.name)).count != group.entries.count })
        {
            throw ToolError.failed("Several files with the same name would get the same checksum file.")
        }
        // A line break in a name cannot be written to an SFV file (it has no escape), and would break the file.
        if options.method == .crc32,
            let bad = groups.lazy.flatMap(\.entries).first(where: { entry in ChecksumFile.hasLineBreak(entry.name) })
        {
            let shown = bad.name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            throw ToolError.failed("\(shown): a name with a line break cannot be written to an SFV file.")
        }
        return groups
    }

    /// Writes the checksum files, all together at the end, or none: a cancel leaves the old ones as they were.
    private static func write(
        _ groups: [(url: URL, entries: [(name: String, digest: [UInt8])])],
        options: CreateOptions,
        run: ToolRun
    ) throws -> [URL] {
        try run.transaction {
            var written: [URL] = []
            for group in groups {
                let mark = ChecksumFile.needsByteOrderMark(
                    names: group.entries.map(\.name),
                    unixFormat: options.unixFormat,
                    alwaysUTF8: options.alwaysUTF8
                )
                try run.provider(for: group.url).createDirectory(at: group.url.deletingLastPathComponent())
                let data = ChecksumFile.contents(
                    group.entries,
                    method: options.method,
                    unixFormat: options.unixFormat,
                    byteOrderMark: mark
                )
                if let url = try run.write(data, to: group.url, deferred: true) {
                    written.append(url)
                }
            }
            return written
        }
    }
}
