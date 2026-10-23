import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import DirectorySyncPlugin

/// The comparison engine over trees in memory and on disk (spec 09 › Comparison algorithm): states,
/// options and masks.
@Suite
internal struct SyncComparing {
    /// The trees and their file systems.
    private let fixture = SyncTreeFixture()

    /// The trees.
    private var memory: MemoryFileSystem { fixture.memory }
    /// The local and the memory file system.
    private var fileSystems: FileSystemRegistry { fixture.fileSystems }
    /// The date most files are dated.
    private var early: Date { SyncTreeFixture.early }

    /// Names that differ only in Unicode form keep rows of their own; a twin that one side holds in the other form is
    /// the same name.
    @Test
    internal func namesThatDifferOnlyInUnicodeFormKeepTheirOwnRows() {
        let (composed, decomposed) = ("caf\u{E9}.txt", "cafe\u{301}.txt")
        for side in ["/L", "/R"] {
            memory.addFile(side + "/" + composed, side == "/L" ? "left composed" : "right composed", modified: early)
            memory.addFile(
                side + "/" + decomposed,
                side == "/L" ? "left decomposed" : "right decomposed",
                modified: early
            )
        }
        // A twin that only one side holds, in the other form, is the same name to that side.
        memory.addFile("/L/\u{FC}ber.txt", "same", modified: early)
        memory.addFile("/R/u\u{308}ber.txt", "same", modified: early)
        let rows = fixture.compare().rows
        let cafe = rows.filter { $0.relativePath.hasPrefix("caf") }
        #expect(cafe.count == 2 && Set(cafe.map { Array($0.relativePath.utf8) }).count == 2)
        #expect(cafe.allSatisfy { $0.left != nil && $0.right != nil })
        #expect(rows.count == 3 && rows.first { $0.relativePath.hasSuffix("ber.txt") }?.state == .equal)

        // Only one spelling asked for: the twin of it on the same side is not taken along.
        let only = fixture.compare("/L", "/R") { $0.onlyNames = [composed] }.rows
        #expect(only.count == 1 && Array(only[0].relativePath.utf8) == Array(composed.utf8))
        let alike = fixture.compare("/L", "/R") { $0.onlyNames = ["u\u{308}ber.txt"] }.rows
        #expect(alike.count == 1 && alike[0].state == .equal)
    }

    /// Every state the comparison tells apart, with its default direction and the counts of the summary.
    @Test
    internal func statesAndDefaultDirections() {
        fixture.makeTree()
        let result = fixture.compare()
        #expect(
            SyncTreeFixture.describe(result.rows) == [
                "equal.txt equal nothing", "left.txt leftOnly copyToRight", "newer-left.txt leftNewer copyToRight",
                "newer-right.txt rightNewer copyToLeft", "right.txt rightOnly copyToLeft", "size.txt different nothing",
                "twin.txt equal nothing",
                "other/only-right.txt rightOnly copyToLeft", "sub/only-left.txt leftOnly copyToRight",
                "sub/deep/inner.txt equal nothing"
            ]
        )
        #expect(result.errors.isEmpty && !result.wasCancelled)
        // /L, /L/sub, /L/sub/deep on the left; /R, /R/other, /R/sub, /R/sub/deep on the right.
        #expect(result.leftDirectories == 3 && result.rightDirectories == 4)
        #expect(
            SyncSummary(result.rows).text
                == "Files found: 10  (Identical: 3, Different: 3, Unique left: 2, Unique right: 2)"
        )
        #expect(SyncSummary([]).text == "Files found: 0")
    }

    /// Without subdirectories only the start folders are compared.
    @Test
    internal func withoutSubdirectoriesOnlyTheStartFolders() {
        fixture.makeTree()
        let rows = fixture.compare { $0.subdirectories = false }.rows
        let allAtTheTop = rows.allSatisfy(\.directory.isEmpty)
        #expect(rows.count == 7 && allAtTheTop)
    }

    /// By content, the pairs that look equal by size and date are read.
    @Test
    internal func byContentReadsPairsThatLookEqual() {
        fixture.makeTree()
        let result = fixture.compare { $0.byContent = true }
        let states = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.relativePath, $0.state) })
        #expect(
            states["twin.txt"] == .different && states["equal.txt"] == .equal && states["sub/deep/inner.txt"] == .equal
        )
        #expect(states["newer-left.txt"] == .leftNewer && states["size.txt"] == .different)
        #expect(!result.rows.contains { $0.state == .pending })
    }

    /// Without dates a pair is only equal or different.
    @Test
    internal func ignoreDateKnowsOnlyEqualAndDifferent() {
        fixture.makeTree()
        memory.addFile("/L/dated.txt", "1234", modified: early)
        memory.addFile("/R/dated.txt", "abcd", modified: early.addingTimeInterval(9_999))
        var states = Dictionary(
            uniqueKeysWithValues: fixture.compare { $0.ignoreDate = true }.rows.map { ($0.relativePath, $0) }
        )
        #expect(states["dated.txt"]?.state == .equal)
        // Same length, different dates: only the size counts.
        #expect(states["newer-left.txt"]?.state == .equal && states["newer-right.txt"]?.state == .different)
        #expect(states["newer-right.txt"]?.action == SyncAction.nothing)
        states = Dictionary(
            uniqueKeysWithValues:
                fixture.compare { options in
                    options.ignoreDate = true
                    options.byContent = true
                }
                .rows.map { row in (row.relativePath, row) }
        )
        #expect(
            states["dated.txt"]?.state == .different && states["newer-left.txt"]?.state == .different
                && states["equal.txt"]?.state == .equal
        )
    }

    /// A mirror deletes what is only on the right and never copies to the left.
    @Test
    internal func asymmetricDeletesOnTheRightAndNeverCopiesLeft() {
        fixture.makeTree()
        let rows = fixture.compare { $0.asymmetric = true }.rows
        let actions = Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0.action) })
        #expect(actions["right.txt"] == .deleteRight && actions["other/only-right.txt"] == .deleteRight)
        #expect(actions["newer-right.txt"] == SyncAction.nothing && actions["left.txt"] == .copyToRight)
        #expect(!rows.contains { $0.action == .copyToLeft })
    }

    /// Dates count as the same within the tolerance, an hour off on request, and moved by the time offset.
    @Test
    internal func dateTolerances() {
        func state(_ seconds: TimeInterval) -> SyncState {
            configured(seconds) { _ in
                // The usual options.
            }
        }
        func configured(_ seconds: TimeInterval, _ configure: (inout SyncOptions) -> Void) -> SyncState {
            var options = SyncOptions()
            configure(&options)
            let left = FileItem(
                url: memory.url("/a"),
                name: "a",
                stat: .init(size: 1, modified: early.addingTimeInterval(seconds))
            )
            let right = FileItem(url: memory.url("/b"), name: "a", stat: .init(size: 1, modified: early))
            return SyncComparison.classify(left: left, right: right, options: options).state
        }
        #expect(state(3) == .equal && state(-3) == .equal && state(4) == .leftNewer && state(-4) == .rightNewer)
        #expect(
            configured(2) { $0.toleranceSeconds = 2 } == .equal
                && configured(3) { $0.toleranceSeconds = 2 } == .leftNewer
        )
        #expect(
            configured(1) { $0.toleranceSeconds = 0 } == .leftNewer
                && configured(0) { $0.toleranceSeconds = 0 } == .equal
        )
        #expect(state(3_600) == .leftNewer && configured(3_600) { $0.ignoreOneHourDifference = true } == .equal)
        #expect(
            configured(-3_602) { $0.ignoreOneHourDifference = true } == .equal
                && configured(7_200) { $0.ignoreOneHourDifference = true } == .leftNewer
        )
        // The right side is two hours behind: its dates are moved before comparing.
        #expect(
            configured(7_200) { $0.timeOffsetHours = 2 } == .equal
                && configured(0) { $0.timeOffsetHours = 2 } == .rightNewer
        )
        #expect(
            SyncComparison.classify(
                left: FileItem(url: memory.url("/a"), name: "a", stat: .init(size: 1, modified: early)),
                right: FileItem(url: memory.url("/b"), name: "a", stat: .init(size: 1, modified: early)),
                options: {
                    var options = SyncOptions()
                    options.byContent = true
                    return options
                }()
            )
            .needsContent
        )
    }

    /// Masks take files, leave files out after `|`, and keep folders named with `/` out.
    @Test
    internal func masksWithExclusions() {
        #expect(SyncMask("*.txt *.md").matchesFile("a.MD") && !SyncMask("*.txt").matchesFile("a.md"))
        #expect(SyncMask("*.* | *.bak;~*").matchesFile("a.txt") && !SyncMask("*.* | *.bak;~*").matchesFile("~a.txt"))
        #expect(
            SyncMask("").matchesFile("anything") && SyncMask("| *.o").matchesFile("a.c")
                && !SyncMask("| *.o").matchesFile("a.o")
        )
        #expect(
            SyncMask("*.* | build/ .git/").excludesFolder("build") && !SyncMask("*.* | build/").excludesFolder("src")
        )
        #expect(SyncMask("*.* | build/").matchesFile("build"))

        fixture.makeTree()
        #expect(
            SyncTreeFixture.describe(fixture.compare { $0.mask = "*.txt | newer* sub/" }.rows) == [
                "equal.txt equal nothing", "left.txt leftOnly copyToRight", "right.txt rightOnly copyToLeft",
                "size.txt different nothing",
                "twin.txt equal nothing", "other/only-right.txt rightOnly copyToLeft"
            ]
        )
        #expect(fixture.compare { $0.mask = "*.md" }.rows.isEmpty)
    }

    /// Only the selected names of the start folders are compared, with everything below them.
    @Test
    internal func onlySelectedNamesOfTheStartFolders() {
        fixture.makeTree()
        let rows = fixture.compare { $0.onlyNames = ["left.txt", "sub", "right.txt"] }.rows
        #expect(
            SyncTreeFixture.describe(rows) == [
                "left.txt leftOnly copyToRight", "right.txt rightOnly copyToLeft",
                "sub/only-left.txt leftOnly copyToRight", "sub/deep/inner.txt equal nothing"
            ]
        )
    }

    /// With "Empty directories", folders on one side only are rows of their own.
    @Test
    internal func emptyDirectoriesAreRowsOfTheirOwn() {
        memory.addDirectory("/L/empty")
        memory.addDirectory("/L/both")
        memory.addDirectory("/R/both")
        memory.addFile("/R/gone/file.txt")
        #expect(SyncTreeFixture.describe(fixture.compare().rows) == ["gone/file.txt rightOnly copyToLeft"])
        #expect(
            SyncTreeFixture.describe(fixture.compare { $0.emptyDirectories = true }.rows)
                == ["empty/ leftOnly copyToRight", "gone/ rightOnly copyToLeft", "gone/file.txt rightOnly copyToLeft"]
        )
        let asymmetric =
            fixture.compare { options in
                options.emptyDirectories = true
                options.asymmetric = true
            }
            .rows
        #expect(
            SyncTreeFixture.describe(asymmetric) == [
                "empty/ leftOnly copyToRight", "gone/ rightOnly deleteRight", "gone/file.txt rightOnly deleteRight"
            ]
        )
        #expect(SyncSummary(asymmetric).files == 1)
    }

    /// Names that differ only in case, and a file that faces a folder, are never synchronized.
    @Test
    internal func namesThatDifferInCaseAndFilesFacingFoldersAreExcluded() {
        memory.addFile("/L/Readme.txt", "a")
        memory.addFile("/R/README.TXT", "a")
        memory.addFile("/L/thing", "a file")
        memory.addFile("/R/thing/inside.txt", "a folder")
        memory.addFile("/L/Docs/a.txt", "a")
        memory.addFile("/R/docs/a.txt", "a")
        memory.addFile("/R/docs/b.txt", "b")
        let rows = fixture.compare().rows
        #expect(
            SyncTreeFixture.describe(rows) == [
                "Readme.txt excluded nothing", "thing excluded nothing", "Docs/a.txt equal nothing",
                "Docs/b.txt rightOnly copyToLeft"
            ]
        )
        #expect(!rows[0].accepts(.copyToRight) && !rows[1].accepts(.deleteBoth) && rows[0].accepts(.nothing))
        // Folders that differ only in case are one folder, and each side keeps its own spelling.
        #expect(rows[3].leftURL.path == "/L/Docs/b.txt" && rows[3].rightURL.path == "/R/docs/b.txt")
    }

    /// A folder that cannot be read is reported and left out on both sides.
    @Test
    internal func aFolderThatCannotBeReadIsLeftOutOnBothSides() {
        fixture.makeTree()
        memory.unreadable = ["/R/sub"]
        let result = fixture.compare { $0.asymmetric = true }
        #expect(result.errors.count == 1 && result.errors[0].contains("/R/sub"))
        // Nothing below it may look unique, or it would be copied or deleted for no reason.
        #expect(!result.rows.contains { $0.directory.hasPrefix("sub/") })
        #expect(result.rows.contains { $0.relativePath == "left.txt" })
    }
}
