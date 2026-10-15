import AFMKernel
import Foundation
import Testing

@testable import DirectorySyncPlugin

/// The rows of Synchronize directories and the list made of them, at the corners the other suites leave.
@MainActor
@Suite
internal struct CovSyncModels {
    private static let folder = URL(fileURLWithPath: "/")

    /// A row in `directory` with the files given.
    private static func row(
        _ directory: String,
        left: FileItem?,
        right: FileItem?,
        state: SyncState
    ) -> SyncRow {
        SyncRow(
            directory: directory,
            isDirectory: false,
            left: left,
            right: right,
            leftDirectory: folder,
            rightDirectory: folder,
            state: state,
            asymmetric: false
        )
    }

    /// A file of this name and size.
    private static func file(_ name: String, size: Int64) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/" + name), name: name, stat: FileItem.Stat(size: size))
    }

    /// Every action has its symbol; no action has none.
    @Test
    internal func everyActionHasItsSymbol() {
        let all: [SyncAction] = [.none, .copyToRight, .copyToLeft, .deleteLeft, .deleteRight, .deleteBoth]
        let symbols = all.map(\.symbol)
        #expect(symbols.first?.isEmpty == true && Set(symbols).count == all.count)
    }

    /// A row without files has no name; an action a row cannot take is followed by the row's first.
    @Test
    internal func rowsWithoutFilesAndActionsTheyCannotTake() {
        #expect(Self.row("", left: nil, right: nil, state: .equal).name.isEmpty)
        var lonely = Self.row("", left: Self.file("a", size: 1), right: nil, state: .leftOnly)
        lonely.action = .deleteBoth
        #expect(lonely.nextAction == .copyToRight)
    }

    /// Rows of a folder that come apart are put in one group; names sort the other way round;
    /// a row without files sorts as nothing.
    @Test
    internal func groupsAndSorting() {
        let rows = [
            Self.row("x/", left: Self.file("b", size: 2), right: nil, state: .leftOnly),
            Self.row("y/", left: nil, right: Self.file("c", size: 3), state: .rightOnly),
            Self.row("x/", left: Self.file("a", size: 1), right: nil, state: .leftOnly),
            Self.row("x/", left: nil, right: nil, state: .equal)
        ]
        let byName = SyncSession.layout(rows: rows, show: .all, sort: (.name, .left, false))
        #expect(byName.entries == [.header("x/"), .row(3), .row(2), .row(0), .header("y/"), .row(1)])
        let bySize = SyncSession.layout(rows: rows, show: .all, sort: (.size, .right, true))
        #expect(bySize.entries == [.header("x/"), .row(3), .row(2), .row(0), .header("y/"), .row(1)])
    }
}
