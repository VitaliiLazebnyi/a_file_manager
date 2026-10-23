/// The outcome of Verify checksums, and its text (spec 08 › Verify window).
internal struct VerifyReport {
    /// The files of one checksum file (or of one check from outside), under its name.
    internal struct Section {
        /// The name of the checksum file.
        internal var title: String
        /// The files it lists, each with what was found, in the order of the file.
        internal var rows: [(name: String, result: VerifyResult)]
    }

    /// The sections, one per checksum file.
    internal var sections: [Section] = []
    /// The methods of the checksums checked, for the title.
    internal var methods: Set<ChecksumMethod> = []

    /// How many files failed, and lines or checksum files could not be read.
    internal var errors: Int { count(.notFound) + count(.readError) + count(.wrongChecksum) + count(.unreadable) }

    /// The names of the files that failed, as the panel knows them; where the checksum file itself is
    /// at fault, its own name (the title of the section).
    internal var failedNames: [String] {
        sections.flatMap { section in
            section.rows.filter { row in row.result != .correct }
                .map { row in row.result == .unreadable ? section.title : row.name }
        }
    }

    /// `<METHOD>: Errors: N`.
    internal var title: String {
        let method = methods.count == 1 ? methods.map(\.reportName).joined() : "Checksums"
        return "\(method): Errors: \(errors)"
    }

    /// The line of the window for one file.
    internal static func row(_ name: String, _ result: VerifyResult) -> String {
        switch result {
        case .correct:
            return "OK:  \(name)"

        case .notFound:
            return "Cannot open input file \(name)!"

        case .readError:
            return "Error reading file \(name)!"

        case .wrongChecksum:
            return "Wrong checksum: \(name)!"

        case .unreadable:
            return "Cannot read \(name)!"
        }
    }

    /// How many rows of all sections have this result.
    internal func count(_ result: VerifyResult) -> Int {
        sections.reduce(0) { total, section in total + section.rows.filter { row in row.result == result }.count }
    }

    /// The rows of the window; with `onlyErrors` just the failures and the summary.
    internal func text(onlyErrors: Bool) -> String {
        var lines: [String] = []
        for section in sections {
            lines.append(section.title + ":")
            lines += section.rows.filter { row in !onlyErrors || row.result != .correct }
                .map { row in Self.row(row.name, row.result) }
            lines.append("")
        }
        lines.append("Errors: \(errors)")
        lines.append(
            "OK: \(count(.correct)), not found: \(count(.notFound)), read error: \(count(.readError)), "
                + "wrong checksum: \(count(.wrongChecksum))"
                + (count(.unreadable) > 0 ? ", unreadable: \(count(.unreadable))" : "")
        )
        return lines.joined(separator: "\n") + "\n"
    }
}
