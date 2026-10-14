import AFMKernel
import FileOperationsPlugin
import Foundation
import TestSupport
import Testing

/// The names of new folders and files: lists, placeholders, counters (spec 07 › New folder, 18 › Placeholders).
@Suite struct NameTemplates {
    /// 2026-10-12 14:03:07.250 UTC, cursor on `Holiday pics.jpeg` in /Volumes/Data/Photos.
    var context: NameTemplate.Context {
        var context = NameTemplate.Context()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        context.calendar = calendar
        context.now = Date(timeIntervalSince1970: 1_791_813_787.25)
        context.cursorName = "Holiday pics.jpeg"
        context.cursorSize = 4096
        context.parentName = "Photos"
        context.grandparentName = "Data"
        context.clipboard = "from: the *clipboard*\nsecond line"
        context.environment = ["USER": "ada", "LONG": "abcdefgh"]
        return context
    }

    func names(_ text: String, quoted: Bool = false) throws -> [String] {
        try NameTemplate.names(from: text, context: context, quotedLists: quoted)
    }

    @Test func plainNamesListsAndNesting() throws {
        #expect(try names("docs") == ["docs"])
        #expect(try names(" made/inner | other ||") == ["made/inner", "other"])
        #expect(try names("p|q/s") == ["p", "q/s"])
        // Brackets mean nothing without the leading <.
        #expect(try names("[Y] plain") == ["[Y] plain"])
        #expect(try names("\"file 1.txt\" \"file 2.txt\"", quoted: true) == ["file 1.txt", "file 2.txt"])
        #expect(try names("\"a b.txt\"|\"c.txt\"|d.txt", quoted: true) == ["a b.txt", "c.txt", "d.txt"])
        #expect(try names("").isEmpty)
    }

    @Test func dateAndTime() throws {
        #expect(try names("<[Y]-[M]-[D] downloads") == ["2026-10-12 downloads"])
        #expect(try names("<[YMD]_[hms]") == ["20261012_140307"])
        #expect(try names("<[y][M] [Y-M-D] [h.m.s] [v]") == ["2610 2026-10-12 14.03.07 250"])
        #expect(try names("<[H][i] [i1]") == ["02pm p"])
        // Offsets on the time source apply to what follows.
        #expect(try names("<[D] [T2+1D][D] [T2-14h][D] [h]") == ["12 13 12 00"])
        #expect(try names("<[T1+2M][Y]-[M]") == ["2026-12"])
    }

    @Test func partsOfTheNameUnderTheCursor() throws {
        #expect(try names("<Copy of [N]") == ["Copy of Holiday pics"])
        #expect(
            try names("<[A] ([E]) in [P] of [G], [S] bytes") == [
                "Holiday pics.jpeg (jpeg) in Photos of Data, 4096 bytes"
            ])
        #expect(
            try names("<[N1][N-4][N2-5]|[N2,3]|[N9-]|[N-4-]|[N-8-5]|[N2--5]") == [
                "Hpolid", "oli", "pics", "pics", "day", "oliday"
            ])
        #expect(try names("<[E02-9]|[E 1-6]x|[E1-3]") == ["00000peg", "jpegx", "jpe"])
        var folder = context
        folder.cursorName = "My.Folder"
        folder.cursorIsFolder = true
        #expect(try NameTemplate.names(from: "<[N]-[E]-", context: folder) == ["My.Folder--"])
    }

    @Test func caseSwitchesEnvironmentClipboardAndBrackets() throws {
        #expect(try names("<[U][N] [L]LOUD [n][E]") == ["HOLIDAY PICS loud jpeg"])
        #expect(try names("<[F]the lord of the rings") == ["The Lord Of The Rings"])
        #expect(try names("<[f]the lord of the rings") == ["The Lord of the Rings"])
        #expect(try names("<[%USER%]_[%LONG%2-4]_[%NONE%]") == ["ada_bcd_"])
        #expect(try names("<[X] [[]x[]]") == ["from_ the _clipboard_ [x]"])
        #expect(try names("<[=tc.size] [Q] [") == ["[=tc.size] [Q] ["])
        var empty = context
        empty.clipboard = nil
        #expect(throws: NameTemplate.Failure.emptyClipboard) { try NameTemplate.names(from: "<[X]", context: empty) }
        #expect(try NameTemplate.names(from: "<a[X+]b", context: empty) == ["ab"])
    }

    @Test func counterRanges() throws {
        // The examples of spec 07 › Counter ranges and optional digit.
        #expect(try names("<1-10>[C]") == ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10"])
        #expect(try names("<1-3>[C]") == ["1", "2", "3"])
        #expect(try names("<1-3>dir[C]") == ["dir1", "dir2", "dir3"])
        #expect(try names("<8-10>Project No [C:3]") == ["Project No 008", "Project No 009", "Project No 010"])
        #expect(try names("<5-6>Example [C] folder") == ["Example 5 folder", "Example 6 folder"])
        #expect(try names("<1-2>[Y]-[M]-[C:2] photos") == ["2026-10-01 photos", "2026-10-02 photos"])
        #expect(try names("<1-3>test[\" (\"C\")\"]") == ["test", "test (2)", "test (3)"])
        #expect(try names("<1-2>[U]part [C] x") == ["PART 1 X", "PART 2 X"])
        // Not at the very start: a literal name.
        #expect(try names("dir<1-3>[C]") == ["dir<1-3>[C]"])
        let preview = NameTemplate.rangePreview("<1-10>[C]", context: context)
        #expect(preview?.first == "01" && preview?.last == "10")
        #expect(NameTemplate.rangePreview("<plain", context: context) == nil)
    }

    @Test func theOptionalDigitFindsTheFirstFreeName() throws {
        var taken = context
        taken.exists = { ["test", "test2", "new", "new (2)", "new (3)"].contains($0) }
        #expect(try NameTemplate.names(from: "<test[C]", context: taken) == ["test3"])
        #expect(try NameTemplate.names(from: "<new[\" (\"C\")\"]", context: taken) == ["new (4)"])
        #expect(try NameTemplate.names(from: "<free[C]|test[C:2]", context: taken) == ["free", "test02"])
        taken.exists = { _ in true }
        #expect(throws: NameTemplate.Failure.noFreeName("full")) {
            try NameTemplate.names(from: "<full[C]", context: taken)
        }
    }
}

/// "Only files of this type" (spec 07 › Only files of this type).
@Suite struct CopyFilters {
    /// The relative paths of a small tree that the filter lets through; folders end in `/`.
    func admitted(_ text: String) -> [String] {
        let filter = CopyFilter(text)
        let tree: [(String, [String])] = [
            ("", ["a.txt", "b.bak", "c.jpg"]), ("docs/", ["d.txt", "e.old"]), ("docs/build/", ["f.txt"]),
            ("src/", ["g.txt"]), ("src/docs/", ["h.txt"]), ("src/docs/deep/", ["i.txt"])
        ]
        var result: [String] = []
        var positions: [String: CopyFilter.Position] = ["": filter.base]
        for (folder, files) in tree {
            if !folder.isEmpty {
                let parts = folder.dropLast().split(separator: "/").map(String.init)
                let parent = parts.dropLast().map { $0 + "/" }.joined()
                guard let above = positions[parent], let inside = filter.entering(parts[parts.count - 1], from: above)
                else { continue }
                positions[folder] = inside
            }
            guard let position = positions[folder] else { continue }
            result += files.filter { filter.admitsFile($0, at: position) }.map { folder + $0 }
        }
        return result
    }

    @Test func emptyAndEverything() {
        #expect(CopyFilter("").isEmpty && CopyFilter("*.*").isEmpty && CopyFilter(" * ").isEmpty)
        #expect(!CopyFilter("*.txt").isEmpty && !CopyFilter("*.* | *.bak").isEmpty && !CopyFilter("| **/").isEmpty)
        #expect(admitted("").count == 9)
    }

    @Test func includeAndExcludeMasks() {
        #expect(
            admitted("*.txt *.JPG") == [
                "a.txt", "c.jpg", "docs/d.txt", "docs/build/f.txt", "src/g.txt", "src/docs/h.txt",
                "src/docs/deep/i.txt"
            ])
        #expect(admitted("*.* | *.bak *.old") == admitted("*.txt *.jpg"))
        #expect(admitted("| *.txt") == ["b.bak", "c.jpg", "docs/e.old"])
        #expect(admitted("\"a.txt\" ?.bak") == ["a.txt", "b.bak"])
    }

    @Test func folderPatterns() {
        #expect(admitted("*.txt | build/ src/") == ["a.txt", "docs/d.txt"])
        // Anchored to the base folder: only its direct subfolder docs is left out.
        #expect(admitted("*.txt | /docs/") == ["a.txt", "src/g.txt", "src/docs/h.txt", "src/docs/deep/i.txt"])
        // Included folders: the base folder's files plus the named folders, direct or at any depth, with or without what is below.
        #expect(admitted("*.txt /docs/") == ["a.txt", "docs/d.txt"])
        #expect(admitted("*.txt /docs/**/") == ["a.txt", "docs/d.txt", "docs/build/f.txt"])
        #expect(admitted("*.txt docs/") == ["a.txt", "docs/d.txt", "src/docs/h.txt"])
        #expect(
            admitted("*.txt docs/**/") == [
                "a.txt", "docs/d.txt", "docs/build/f.txt", "src/docs/h.txt", "src/docs/deep/i.txt"
            ])
        #expect(admitted("*.txt docs\\ | /") == ["docs/d.txt", "src/docs/h.txt"])
        #expect(CopyFilter("*.* | **/").skipsEmptyFolders && !CopyFilter("*.*").skipsEmptyFolders)
    }
}

@Suite struct Switches {
    @Test func commandOptionsAreRead() {
        // The example of spec 17 › Commands with parameters.
        let switches = CommandSwitches.parse("/V0H1T=\"c:\\test\\\"W=\"\"\"a test.*\"\" test2.*\"")
        #expect(switches == ["V": "0", "H": "1", "T": "c:\\test\\", "W": "\"a test.*\" test2.*"])
        #expect(CommandSwitches.parse("/O3 /G S") == ["O": "3", "G": "1", "S": "1"])
        #expect(CommandSwitches.parse("N=\"a|b\" G") == ["N": "a|b", "G": "1"])
        #expect(CommandSwitches.parse("").isEmpty)
    }
}

/// The operation log (spec 13 › Operation › Log file).
@Suite struct OperationLogs {
    let box: Sandbox
    var configuration = OperationLog.Configuration()

    init() throws {
        box = try Sandbox()
        configuration.isEnabled = true
        configuration.file = box.url("logs/operations.log")
    }

    /// A clock the test moves.
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_791_813_787)
    }

    @Test func linesAreWrittenInOrderOffTheCallingThread() {
        let clock = Clock()
        let log = OperationLog(configuration, now: { clock.now })
        log.write(OperationRecord(.copy, source: "/a/one.txt", target: "/b/one.txt"))
        log.write(OperationRecord(.delete, source: "/a/two.txt", status: .failed("Permission denied")))
        log.write(OperationRecord(.move, source: "/a/three.txt", target: "/b/three.txt", status: .skipped))
        log.flush()
        let lines = (box.read("logs/operations.log") ?? "").split(separator: "\n").map { String($0.dropFirst(21)) }
        #expect(
            lines == [
                "Copy: /a/one.txt -> /b/one.txt", "Error: Delete: /a/two.txt: Permission denied",
                "Skipped: Move: /a/three.txt -> /b/three.txt"
            ])
        #expect(
            box.read("logs/operations.log")?.range(
                of: #"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d: Copy"#, options: .regularExpression) != nil)
    }

    @Test func manyThreadsCanWriteAtOnce() {
        let log = OperationLog(configuration)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            log.write(OperationRecord(.copy, source: "/a/\(index)", target: "/b/\(index)"))
        }
        log.flush()
        let lines = (box.read("logs/operations.log") ?? "").split(separator: "\n")
        #expect(lines.count == 200 && Set(lines.map { $0.split(separator: " ").last ?? "" }).count == 200)
    }

    @Test func onlyWhatIsWantedIsLogged() {
        var quiet = configuration
        quiet.logsDeletes = false
        quiet.logsSkipped = false
        quiet.logsFolders = false
        let log = OperationLog(quiet)
        log.write(OperationRecord(.copy, source: "kept"))
        log.write(OperationRecord(.copy, source: "skipped", status: .skipped))
        log.write(OperationRecord(.trash, source: "trashed"))
        log.write(OperationRecord(.makeFolder, source: "folder"))
        log.write(OperationRecord(.rename, source: "failed", status: .failed("no")))
        log.flush()
        let text = box.read("logs/operations.log") ?? ""
        #expect(
            text.contains("kept") && text.contains("Error: Rename: failed: no") && !text.contains("skipped")
                && !text.contains("trashed")
                && !text.contains("folder"))

        var off = configuration
        off.isEnabled = false
        off.file = box.url("logs/off.log")
        let silent = OperationLog(off)
        silent.write(OperationRecord(.copy, source: "x"))
        silent.flush()
        #expect(!box.exists("logs/off.log"))
    }

    @Test func rotationBySizeKeepsALimitedNumberOfCopies() {
        var rotating = configuration
        rotating.rotation = .size(200)
        rotating.keepCount = 2
        let log = OperationLog(rotating)
        for index in 0..<12 {
            log.write(OperationRecord(.copy, source: "/a/" + String(repeating: "x", count: 60) + "\(index)"))
            log.flush()
            // The copies are told apart by their dates.
            Thread.sleep(forTimeInterval: 0.02)
        }
        let names = namesOnDisk(box.url("logs"))
        #expect(names.contains("operations.log") && names.count == 3)
        #expect(names.allSatisfy { $0.hasPrefix("operations.") && $0.hasSuffix(".log") })
        #expect((box.read("logs/operations.log") ?? "").utf8.count <= 200)
    }

    @Test func dailyRotationStartsANewFileAfterMidnight() throws {
        var rotating = configuration
        rotating.rotation = .daily
        let clock = Clock()
        let log = OperationLog(rotating, now: { clock.now })
        log.write(OperationRecord(.copy, source: "today"))
        log.flush()
        // The file was last written two days ago, as far as the disk knows.
        let before = Date(timeIntervalSinceNow: -2 * 86400)
        try FileManager.default.setAttributes(
            [.modificationDate: before], ofItemAtPath: box.url("logs/operations.log").path)
        clock.now = Date()
        log.write(OperationRecord(.copy, source: "later"))
        log.flush()
        let names = namesOnDisk(box.url("logs"))
        #expect(names.count == 2 && box.read("logs/operations.log")?.contains("later") == true)
        let old = try #require(names.first { $0 != "operations.log" })
        #expect(
            old.range(of: #"^operations\.\d{4}-\d\d-\d\d\.log$"#, options: .regularExpression) != nil
                && box.read("logs/" + old)?.contains("today") == true)
    }
}
