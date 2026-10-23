import AFMKernel
import Foundation

/// Verify checksums: the files that checksum files list, or that carry a checksum from outside, hashed and
/// checked.
extension ChecksumRun {
    /// A file listed in a checksum file, waiting to be hashed.
    private struct Pending {
        /// The section of the report it belongs to.
        var section: Int
        /// Its name as the checksum file has it.
        var name: String
        /// Where it was looked for.
        var url: URL
        /// Its line in the checksum file.
        var entry: ChecksumFile.Entry
        /// The methods its digest may be of, the likeliest first.
        var methods: [ChecksumMethod]
        /// Its size; nil when it is not there (or is a folder).
        var size: Int64?
    }

    /// Checks the files listed in checksum files against their checksums.
    internal static func verify(checksumFiles: [FileItem], run: ToolRun) throws -> VerifyReport {
        var report = VerifyReport()
        var pending: [Pending] = []
        for file in checksumFiles {
            try run.checkCancelled()
            pending += try listed(in: file, run: run, into: &report)
        }
        for file in pending {
            // The title names the method; of several that share a length, the first (SHA-2).
            if let named = file.methods.first {
                report.methods.insert(named)
            }
        }
        let present = pending.filter { file in file.size != nil }
        let sizes = pending.compactMap(\.size)
        run.expect(bytes: sizes.reduce(0) { total, size in total.addingSaturated(size) }, items: sizes.count)
        run.show(["Verifying checksums"])
        let digests = digests(
            of: present.map { file in HashRequest(url: file.url, methods: file.methods, expected: file.entry.digest) },
            run: run
        )
        try run.checkCancelled()
        var hashed = digests.makeIterator()
        for file in pending {
            var result = VerifyResult.notFound
            if file.size != nil, let outcome = hashed.next() {
                switch outcome {
                case .success(let found):
                    result = found.contains { digest in digest.hex == file.entry.digest } ? .correct : .wrongChecksum

                case .failure:
                    result = .readError
                }
            }
            report.sections[file.section].rows.append((file.name, result))
        }
        return report
    }

    /// Reads one checksum file into a new section of the report: what of it cannot be read, and the files it
    /// lists, to be hashed.
    private static func listed(in file: FileItem, run: ToolRun, into report: inout VerifyReport) throws -> [Pending] {
        let provider = try run.provider(for: file.url)
        let folder = file.url.deletingLastPathComponent()
        report.sections.append(VerifyReport.Section(title: file.name, rows: []))
        let section = report.sections.count - 1
        let parsed: ChecksumFile.Parsed
        do {
            parsed = ChecksumFile.parseLines(
                ChecksumFile.text(from: try run.contents(of: file.url, limit: ToolRun.contentsLimit)),
                fileName: file.name
            )
        } catch {
            // A checksum file that cannot be read is an error of its own; the others are still checked.
            try run.checkCancelled()
            report.sections[section].rows.append(("the file (\(error.localizedDescription))", .unreadable))
            return []
        }
        // What cannot be read is never "no errors": every such line counts, and so does a file without checksums.
        for number in parsed.unreadableLines {
            report.sections[section].rows.append(("line \(number)", .unreadable))
        }
        if parsed.entries.isEmpty, parsed.unreadableLines.isEmpty {
            report.sections[section].rows.append(("any checksum (the file has none)", .unreadable))
        }
        return parsed.entries.map { entry in
            let (url, item) = locate(entry.name, in: folder, provider: provider, run: run)
            return Pending(
                section: section,
                name: entry.name,
                url: url,
                entry: entry,
                methods: entry.method.map { method in [method] }
                    ?? ChecksumMethod.candidates(hexDigits: entry.digest.count),
                size: item.flatMap { found in found.isDirectory ? nil : found.size }
            )
        }
    }

    /// Where a file named in a checksum file in `folder` is, and the file if it is there.
    ///
    /// A name is taken as written; a Windows path is tried with `/` when that finds nothing. An absolute path
    /// stands for itself, not below the checksum file's folder.
    private static func locate(
        _ name: String,
        in folder: URL,
        provider: any FileSystemProvider,
        run: ToolRun
    ) -> (url: URL, item: FileItem?) {
        func resolve(_ name: String) -> URL {
            if name.hasPrefix("/"), folder.isFileURL {
                return URL(fileURLWithPath: name).standardized
            }
            return folder.appendingPathComponent(name, isDirectory: false).standardized
        }
        var url = resolve(name)
        var item = provider.item(at: url, cancellation: run.cancellation)
        if item == nil, name.contains("\\") {
            url = resolve(name.replacingOccurrences(of: "\\", with: "/"))
            item = provider.item(at: url, cancellation: run.cancellation)
        }
        return (url, item)
    }

    /// Checks files against one checksum each, given from outside: the clipboard, or a CRC32
    /// in square brackets in the name.
    ///
    /// Every method the length of the checksum allows is tried.
    internal static func verify(_ files: [(item: FileItem, digest: String)], title: String, run: ToolRun) throws
        -> VerifyReport
    {
        var report = VerifyReport()
        let methods = files.map { file in ChecksumMethod.candidates(hexDigits: file.digest.count) }
        if let first = methods.first?.first {
            report.methods = [first]
        }
        run.expect(bytes: files.reduce(0) { total, file in total.addingSaturated(file.item.size) }, items: files.count)
        run.show(["Verifying checksums"])
        let digests = digests(
            of: zip(files, methods)
                .map { file, candidates in
                    HashRequest(url: file.item.url, methods: candidates, expected: file.digest.lowercased())
                },
            run: run
        )
        try run.checkCancelled()
        var rows: [(name: String, result: VerifyResult)] = []
        for (index, file) in files.enumerated() {
            switch digests[index] {
            case .success(let found):
                let wanted = file.digest.lowercased()
                if let match = found.firstIndex(where: { digest in digest.hex == wanted }) {
                    report.methods = [methods[index][match]]
                }
                rows.append(
                    (file.item.name, found.contains { digest in digest.hex == wanted } ? .correct : .wrongChecksum)
                )

            case .failure:
                rows.append((file.item.name, .readError))
            }
        }
        report.sections = [VerifyReport.Section(title: title, rows: rows)]
        return report
    }

    /// A CRC32 in square brackets in a file name: `Movie [1A2B3C4D].mkv`.
    internal static func checksumInName(_ name: String) -> String? {
        guard name.utf8.contains(UInt8(ascii: "[")), let regex = bracketedChecksum,
            let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
            let range = Range(match.range(at: 1), in: name)
        else {
            return nil
        }
        return name[range].lowercased()
    }

    /// A checksum on the clipboard: nothing but hex digits of a known length.
    internal static func checksum(fromClipboard text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmed.allSatisfy({ character in character.isASCII && character.isHexDigit }),
            !ChecksumMethod.candidates(hexDigits: trimmed.count).isEmpty
        else {
            return nil
        }
        return trimmed.lowercased()
    }
}
