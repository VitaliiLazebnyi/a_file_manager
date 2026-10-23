import AFMContracts
import AFMKernel
import Foundation

/// Lays a file list out in pages of text: a header line on every page, the rows in the
/// panel's format, and a footer with the totals after the last row (spec 12 › Print directory
/// dialog, 12 › Print margins and header).
///
/// Pure: the same input gives the same pages.
internal struct DirectoryListFormatter {
    /// The header of a list unless the user set another: the base folder and the page number.
    internal static let defaultHeader = "%d - Page %p/%t"

    /// The header with its placeholders; empty turns the header off.
    internal var header = Self.defaultHeader
    /// Lines on a page, header included.
    internal var linesPerPage = 60
    /// Full view prints size, date and attributes; Brief prints the names only.
    internal var isDetailed = true
    /// Names longer than this are not padded to; the columns then move for that row.
    internal var nameWidthLimit = 60

    /// `%p` page, `%t` number of pages, `%d` base folder, `%D` date, `%T` time, `%%` a percent sign.
    internal static func expand(_ template: String, directory: String, page: Int, pages: Int, now: Date) -> String {
        var result = ""
        var characters = template.makeIterator()
        while let character = characters.next() {
            guard character == "%" else {
                result.append(character)
                continue
            }
            switch characters.next() {
            case "p":
                result += String(page)

            case "t":
                result += String(pages)

            case "d":
                result += directory

            case "D":
                result += DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .none)

            case "T":
                result += DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium)

            case "%":
                result.append("%")

            case let other?:
                result += "%" + String(other)

            case nil:
                result.append("%")
            }
        }
        return result
    }

    /// The totals line: `3,607 k in 2 files`, with the folders when there are any.
    internal static func footer(_ rows: [ListRow]) -> String {
        let files = rows.filter { !$0.isFolder }
        let folders = rows.count - files.count
        let text = "\(Format.kilobytes(files.reduce(0) { $0.addingSaturated($1.size) })) in \(files.count) files"
        return folders > 0 ? text + ", \(folders) folders" : text
    }

    /// The line of `row`: its name (a folder's with a `/`), and in Full view the size right-aligned
    /// in `sizeWidth` columns, the date and the attributes, the name padded to `nameWidth`.
    internal func line(_ row: ListRow, nameWidth: Int, sizeWidth: Int) -> String {
        let name = row.isFolder && !row.name.hasSuffix("/") ? row.name + "/" : row.name
        guard isDetailed else {
            return name
        }
        let size = row.isFolder ? "<DIR>" : Format.bytes(row.size)
        let padded = name.count < nameWidth ? name.padding(toLength: nameWidth, withPad: " ", startingAt: 0) : name
        let sizeColumn = String(repeating: " ", count: max(0, sizeWidth - size.count)) + size
        return "\(padded)  \(sizeColumn)  \(Format.date(row.modified))  " + Format.permissions(row.permissions)
    }

    /// The lines of the list without headers: the rows, an empty line, the footer.
    internal func body(_ rows: [ListRow]) -> [String] {
        let nameWidth = min(nameWidthLimit, rows.map { $0.name.count + ($0.isFolder ? 1 : 0) }.max() ?? 0)
        let sizeWidth = rows.map { $0.isFolder ? 5 : Format.bytes($0.size).count }.max() ?? 0
        return rows.map { line($0, nameWidth: nameWidth, sizeWidth: sizeWidth) } + [
            "", Self.footer(rows)
        ]
    }

    /// The pages, each as its lines, the header placeholders filled in for `now`.
    ///
    /// There is always at least one page.
    internal func pages(directory: String, rows: [ListRow], now: Date) -> [[String]] {
        let lines = body(rows)
        let hasHeader = !header.isEmpty
        let perPage = max(1, linesPerPage - (hasHeader ? 2 : 0))
        let chunks = stride(from: 0, to: lines.count, by: perPage)
            .map { start in
                Array(lines[start..<min(start + perPage, lines.count)])
            }
        return chunks.enumerated()
            .map { index, chunk in
                guard hasHeader else {
                    return chunk
                }
                let title = Self.expand(header, directory: directory, page: index + 1, pages: chunks.count, now: now)
                return [title, ""] + chunk
            }
    }

    /// The whole list as one text; pages are separated by a form feed, as text printers expect.
    internal func text(directory: String, rows: [ListRow], now: Date) -> String {
        pages(directory: directory, rows: rows, now: now).map { $0.joined(separator: "\n") }
            .joined(
                separator: "\n\u{0C}\n"
            )
    }
}
