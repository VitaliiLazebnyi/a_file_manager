import AFMContracts
import AFMKernel
import AppKit

/// One line of a printed file list (spec 12 › Printing).
struct ListRow: Equatable {
    /// The name, or the path below the list's base folder for an item of a subfolder.
    let name: String
    let isFolder: Bool
    let size: Int64
    let modified: Date
    let permissions: UInt16

    init(
        name: String,
        isFolder: Bool,
        size: Int64 = 0,
        modified: Date = Date(timeIntervalSince1970: 0),
        permissions: UInt16 = 0o644
    ) {
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }

    init(_ item: FileItem, path: String? = nil) {
        self.init(
            name: path ?? item.name,
            isFolder: item.isFolder,
            size: item.isFolder ? (item.computedSize ?? 0) : item.size,
            modified: item.modified,
            permissions: item.permissions
        )
    }
}

/// Which files a list with subfolders includes: `*.doc *.txt`, or `*.* | *.bak` to leave
/// some out (spec 18 › Core syntax).
///
/// Folders are always listed and entered.
struct ListMask {
    private let include: FileMask?
    private let exclude: FileMask?

    init(_ text: String) {
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        // An empty include part means everything.
        include = parts.first.flatMap { $0.isEmpty ? nil : FileMask($0) }
        exclude = parts.count > 1 && !parts[1].isEmpty ? FileMask(parts[1]) : nil
    }

    func matches(_ name: String) -> Bool {
        (include?.matches(name) ?? true) && !(exclude?.matches(name) ?? false)
    }
}

/// Reads the rows of a list with subfolders through the file systems.
///
/// Blocks; runs on a job's thread. The subfolders of one folder are read on all cores at once,
/// since on a server each listing is a trip of its own; the rows keep the order of the names.
struct ListCollector {
    let fileSystems: FileSystemRegistry
    let showHidden: Bool
    let mask: ListMask
    /// How many levels of subfolders are entered; negative means all (spec: `-1` = unlimited).
    let depth: Int
    let cancellation: CancellationFlag

    func rows(of items: [FileItem]) -> [ListRow] {
        rows(of: items, prefix: "", level: 0)
    }

    private func rows(of items: [FileItem], prefix: String, level: Int) -> [ListRow] {
        let wanted = Sorter.sorted(
            items.filter { $0.isRealDirectory || mask.matches($0.name) },
            numeric: true,
            byName: \.name
        )
        return
            Parallel.map(wanted) { item -> [ListRow] in
                let path = prefix + item.name
                var rows = [ListRow(item, path: path)]
                guard item.isRealDirectory, depth < 0 || level < depth, !cancellation.isCancelled,
                    let children = try? fileSystems.provider(for: item.url)
                        .list(
                            item.url,
                            showHidden: showHidden,
                            cancellation: cancellation
                        ),
                    !cancellation.isCancelled
                else { return rows }
                rows += self.rows(of: children, prefix: path + "/", level: level + 1)
                return rows
            }
            .flatMap { $0 }
    }
}

/// Lays a file list out in pages of text: a header line on every page, the rows in the
/// panel's format, and a footer with the totals after the last row (spec 12 › Print directory
/// dialog, 12 › Print margins and header).
///
/// Pure: the same input gives the same pages.
struct DirectoryListFormatter {
    static let defaultHeader = "%d - Page %p/%t"

    /// The header with its placeholders; empty turns the header off.
    var header = Self.defaultHeader
    /// Lines on a page, header included.
    var linesPerPage = 60
    /// Full view prints size, date and attributes; Brief prints the names only.
    var isDetailed = true
    /// Names longer than this are not padded to; the columns then move for that row.
    var nameWidthLimit = 60

    /// `%p` page, `%t` number of pages, `%d` base folder, `%D` date, `%T` time, `%%` a percent sign.
    static func expand(_ template: String, directory: String, page: Int, pages: Int, now: Date) -> String {
        var result = ""
        var characters = template.makeIterator()
        while let character = characters.next() {
            guard character == "%" else {
                result.append(character)
                continue
            }
            switch characters.next() {
            case "p": result += String(page)
            case "t": result += String(pages)
            case "d": result += directory
            case "D": result += DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .none)
            case "T": result += DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium)
            case "%": result.append("%")
            case let other?: result += "%" + String(other)
            case nil: result.append("%")
            }
        }
        return result
    }

    /// The totals line: `3,607 k in 2 files`, with the folders when there are any.
    static func footer(_ rows: [ListRow]) -> String {
        let files = rows.filter { !$0.isFolder }
        let folders = rows.count - files.count
        let text = "\(Format.kilobytes(files.reduce(0) { $0.addingSaturated($1.size) })) in \(files.count) files"
        return folders > 0 ? text + ", \(folders) folders" : text
    }

    func line(_ row: ListRow, nameWidth: Int, sizeWidth: Int) -> String {
        let name = row.isFolder && !row.name.hasSuffix("/") ? row.name + "/" : row.name
        guard isDetailed else { return name }
        let size = row.isFolder ? "<DIR>" : Format.bytes(row.size)
        let padded = name.count < nameWidth ? name.padding(toLength: nameWidth, withPad: " ", startingAt: 0) : name
        return
            "\(padded)  \(String(repeating: " ", count: max(0, sizeWidth - size.count)))\(size)  \(Format.date(row.modified))  "
            + Format.permissions(row.permissions)
    }

    /// The lines of the list without headers: the rows, an empty line, the footer.
    func body(_ rows: [ListRow]) -> [String] {
        let nameWidth = min(nameWidthLimit, rows.map { $0.name.count + ($0.isFolder ? 1 : 0) }.max() ?? 0)
        let sizeWidth = rows.map { $0.isFolder ? 5 : Format.bytes($0.size).count }.max() ?? 0
        return rows.map { line($0, nameWidth: nameWidth, sizeWidth: sizeWidth) } + [
            "", Self.footer(rows)
        ]
    }

    /// The pages, each as its lines.
    ///
    /// There is always at least one page.
    func pages(directory: String, rows: [ListRow], now: Date = Date()) -> [[String]] {
        let lines = body(rows)
        let hasHeader = !header.isEmpty
        let perPage = max(1, linesPerPage - (hasHeader ? 2 : 0))
        let chunks = stride(from: 0, to: lines.count, by: perPage)
            .map {
                Array(lines[$0..<min($0 + perPage, lines.count)])
            }
        return chunks.enumerated()
            .map { index, chunk in
                guard hasHeader else { return chunk }
                return [
                    Self.expand(
                        header,
                        directory: directory,
                        page: index + 1,
                        pages: chunks.count,
                        now: now
                    ), ""
                ] + chunk
            }
    }

    /// The whole list as one text; pages are separated by a form feed, as text printers expect.
    func text(directory: String, rows: [ListRow], now: Date = Date()) -> String {
        pages(directory: directory, rows: rows, now: now).map { $0.joined(separator: "\n") }
            .joined(
                separator: "\n\u{0C}\n"
            )
    }
}

/// Draws pages of text for the printer: one page of the list on each sheet, in a fixed-width
/// font sized so that the page's lines fit the sheet.
///
/// Main thread only, like every view.
final class PagePrintView: NSView {
    private let pages: [[String]]
    private let pageSize: NSSize
    private let attributes: [NSAttributedString.Key: Any]
    private let lineHeight: CGFloat

    /// `longestLine` is the length of the longest line, when the caller has measured it
    /// already (off the main thread, for a long list).
    ///
    /// Without it the lines are measured here, in UTF-16 units (a count that does not cut every
    /// line into characters).
    init(pages: [[String]], longestLine: Int? = nil, linesPerPage: Int, printInfo: NSPrintInfo) {
        self.pages = pages
        let bounds = printInfo.imageablePageBounds
        let paper = printInfo.paperSize
        let width = min(bounds.width, paper.width - printInfo.leftMargin - printInfo.rightMargin)
        let height = min(bounds.height, paper.height - printInfo.topMargin - printInfo.bottomMargin)
        pageSize = NSSize(width: max(width, 100), height: max(height, 100))
        lineHeight = pageSize.height / CGFloat(max(linesPerPage, 1))
        // The longest line decides the width a character may have; 0.6 em is the advance of the fixed-width system font.
        let longest = CGFloat(
            max(
                longestLine ?? pages.reduce(0) { longest, page in page.reduce(longest) { max($0, $1.utf16.count) } },
                1
            )
        )
        let size = max(4, min(11, lineHeight / 1.25, pageSize.width / longest / 0.6))
        attributes = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), .foregroundColor: NSColor.black
        ]
        super
            .init(
                frame: NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height * CGFloat(max(pages.count, 1)))
            )
    }

    required init?(coder _: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(pages.count, 1))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, lines) in pages.enumerated() where rectForPage(index + 1).intersects(dirtyRect) {
            let top = CGFloat(index) * pageSize.height
            for (row, line) in lines.enumerated() {
                (line as NSString)
                    .draw(
                        at: NSPoint(x: 0, y: top + CGFloat(row) * lineHeight),
                        withAttributes: attributes
                    )
            }
        }
    }
}
