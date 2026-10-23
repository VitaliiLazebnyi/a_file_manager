import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// File lists: headers, rows, pages, masks and subfolders.
extension SystemToolsTypes {
    /// The placeholders of the header are filled in; unknown ones stay as they are.
    @Test
    internal func headerPlaceholdersAreFilledIn() {
        #expect(
            DirectoryListFormatter.expand("%d - Page %p/%t", directory: "/tmp/A", page: 2, pages: 3, now: now)
                == "/tmp/A - Page 2/3"
        )
        #expect(DirectoryListFormatter.expand("100%% %x %", directory: "", page: 1, pages: 1, now: now) == "100% %x %")
        let stamp = DirectoryListFormatter.expand("%D|%T", directory: "", page: 1, pages: 1, now: now)
            .split(
                separator: "|"
            )
        #expect(stamp.count == 2 && stamp.allSatisfy { !$0.isEmpty && !$0.contains("%") })
    }

    /// Rows are aligned in columns and the footer counts the files and folders.
    @Test
    internal func rowsAreAlignedAndTheFooterCounts() {
        let rows = [
            ListRow(name: "images", isFolder: true, size: 0, modified: now, permissions: 0o755),
            ListRow(name: "green.png", isFolder: false, size: 782, modified: now, permissions: 0o644),
            ListRow(name: "a", isFolder: false, size: 1_234_567, modified: now, permissions: 0o644)
        ]
        let date = Format.date(now)
        #expect(
            DirectoryListFormatter().body(rows) == [
                "images/        <DIR>  \(date)  rwxr-xr-x",
                "green.png        782  \(date)  rw-r--r--",
                "a          1,234,567  \(date)  rw-r--r--",
                "", "1,206 k in 2 files, 1 folders"
            ]
        )
        #expect(DirectoryListFormatter.footer([rows[1]]) == "1 k in 1 files")
        var brief = DirectoryListFormatter()
        brief.isDetailed = false
        #expect(brief.body(rows).prefix(3) == ["images/", "green.png", "a"])
    }

    /// Long lists are split into pages, each with its header.
    @Test
    internal func longListsAreSplitIntoPagesWithAHeaderEach() {
        let rows = (1...10)
            .map { number in
                ListRow(name: "file\(number)", isFolder: false, size: 1, modified: now, permissions: 0o644)
            }
        var formatter = DirectoryListFormatter()
        formatter.isDetailed = false
        formatter.linesPerPage = 6
        // Ten rows, an empty line and the footer: twelve lines in pages of four below the header.
        let pages = formatter.pages(directory: "/A", rows: rows, now: now)
        #expect(pages.count == 3 && pages[0] == ["/A - Page 1/3", "", "file1", "file2", "file3", "file4"])
        #expect(pages[2] == ["/A - Page 3/3", "", "file9", "file10", "", "0 k in 10 files"])
        #expect(formatter.text(directory: "/A", rows: rows, now: now).components(separatedBy: "\u{0C}").count == 3)
        formatter.header = ""
        #expect(formatter.pages(directory: "/A", rows: rows, now: now).map(\.count) == [6, 6])
        #expect(formatter.pages(directory: "/A", rows: [], now: now) == [["", "0 k in 0 files"]])
    }

    /// Masks include files, and leave out those after a `|`.
    @Test
    internal func masksIncludeAndExclude() {
        #expect(ListMask("*.doc *.txt").matches("a.txt") && !ListMask("*.doc *.txt").matches("a.png"))
        #expect(ListMask("*.* | *.bak *.~*").matches("a.txt") && !ListMask("*.* | *.bak *.~*").matches("a.bak"))
        #expect(
            ListMask("|*.exe").matches("a.txt") && !ListMask("|*.exe").matches("a.exe")
                && ListMask("").matches("anything")
        )
    }

    /// Subfolders are collected to the given depth, with the mask and the hidden items as asked.
    @Test
    internal func subfoldersAreCollectedToTheGivenDepth() {
        let (fileSystems, memory) = makeFileSystems()
        for path in ["/A/b.txt", "/A/a.md", "/A/sub/c.txt", "/A/sub/deeper/d.txt", "/A/.hidden/e.txt"] {
            memory.addFile(path)
        }
        func names(depth: Int, mask: String = "*.*", hidden: Bool = false) -> [String] {
            let items = (try? memory.list(memory.url("/A"), showHidden: hidden)) ?? []
            return ListCollector(
                fileSystems: fileSystems,
                showHidden: hidden,
                mask: ListMask(mask),
                depth: depth,
                cancellation: CancellationFlag()
            )
            .rows(of: items).map(\.name)
        }
        #expect(names(depth: 0) == ["a.md", "b.txt", "sub"])
        #expect(names(depth: 1) == ["a.md", "b.txt", "sub", "sub/c.txt", "sub/deeper"])
        #expect(names(depth: -1, mask: "*.txt") == ["b.txt", "sub", "sub/c.txt", "sub/deeper", "sub/deeper/d.txt"])
        #expect(names(depth: -1, hidden: true).contains(".hidden/e.txt"))
        let cancelled = CancellationFlag()
        cancelled.cancel()
        let items = (try? memory.list(memory.url("/A"), showHidden: false)) ?? []
        #expect(
            ListCollector(
                fileSystems: fileSystems,
                showHidden: false,
                mask: ListMask("*"),
                depth: -1,
                cancellation: cancelled
            )
            .rows(of: items).map(\.name) == ["a.md", "b.txt", "sub"]
        )
    }
}
