import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// The pure parts of the file-properties plugin: the comment file format, permission and date
/// entries, command parameters, link paths and the wording of the space report.
@Suite struct FilePropertiesFormats {
    // MARK: descript.ion

    @Test func readsTheCommentFileAsTotalCommanderWritesIt() {
        // ANSI with ü = 0xFC, a multi-line comment with its marker bytes, a quoted name.
        var bytes = Data("sel.txt Selection list ".utf8) + Data([0xFC, 0x0D, 0x0A])
        bytes += Data("ro.txt first line\\nsecond line".utf8) + Data([0x04, 0xC2, 0x0D, 0x0A])
        bytes += Data("\"long name.txt\" Comment of a name with spaces\r\n".utf8)
        let file = DescriptIon(data: bytes)
        #expect(file.encoding == .ansi)
        #expect(file.comment(for: "sel.txt") == "Selection list ü")
        #expect(file.comment(for: "RO.TXT") == "first line\nsecond line")
        #expect(file.comment(for: "long name.txt") == "Comment of a name with spaces")
        #expect(file.comment(for: "other.txt") == nil)
        // Written back, the bytes are the same.
        #expect(file.data() == bytes)
    }

    @Test func changesCommentsAndKeepsTheOrder() {
        var file = DescriptIon(data: Data("a.txt one\r\nb.txt two\r\n".utf8))
        file.setComment("changed", for: "A.TXT")
        file.setComment("new\r\nlines \n", for: "my file")
        file.setComment("", for: "b.txt")
        file.setComment("", for: "missing")
        #expect(file.entries.map(\.name) == ["a.txt", "my file"])
        #expect(
            String(data: file.data(), encoding: .windowsCP1252)
                == "a.txt changed\r\n\"my file\" new\\nlines\u{04}\u{C2}\r\n")
        file.setComment("", for: "a.txt")
        file.setComment("", for: "my file")
        #expect(file.isEmpty)
    }

    @Test func choosesAnEncodingThatHoldsEveryCharacter() {
        var plain = DescriptIon()
        plain.setComment("größer", for: "a.txt")
        #expect(plain.data() == "a.txt größer\r\n".data(using: .windowsCP1252))
        // Outside the code page: UTF-16 LE with a byte-order mark.
        plain.setComment("日本語", for: "b.txt")
        let wide = plain.data()
        #expect(wide.starts(with: [0xFF, 0xFE]))
        let again = DescriptIon(data: wide)
        #expect(
            again.encoding == .utf16LittleEndian && again.comment(for: "b.txt") == "日本語"
                && again.comment(for: "a.txt") == "größer")
        // A UTF-8 file stays UTF-8, with or without its mark.
        let utf8 = DescriptIon(data: Data([0xEF, 0xBB, 0xBF]) + Data("a.txt größer\r\n".utf8))
        #expect(
            utf8.encoding == .utf8(bom: true) && utf8.comment(for: "a.txt") == "größer"
                && utf8.data().starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(DescriptIon(data: Data("a.txt größer\n".utf8)).encoding == .utf8(bom: false))
        #expect(DescriptIon(data: Data([0xFE, 0xFF, 0x00, 0x61, 0x00, 0x20, 0x00, 0x62])).comment(for: "a") == "b")
    }

    // MARK: Permissions

    @Test func readsPermissionsInEveryNotation() {
        #expect(PermissionChange("") == .unchanged && PermissionChange("  ") == .unchanged)
        // An octal mode is the whole mode, as for `chmod` (review 2, F028): three digits clear the special bits.
        #expect(PermissionChange("755")?.applied(to: 0o4600, isDirectory: false) == 0o755)
        #expect(PermissionChange("0755")?.applied(to: 0o4600, isDirectory: false) == 0o755)
        #expect(PermissionChange("rw-r-----")?.applied(to: 0o777, isDirectory: false) == 0o640)
        #expect(PermissionChange("u+x,go-w")?.applied(to: 0o666, isDirectory: false) == 0o744)
        #expect(PermissionChange("+x")?.applied(to: 0o644, isDirectory: false) == 0o755)
        #expect(PermissionChange("go=r")?.applied(to: 0o777, isDirectory: false) == 0o744)
        #expect(PermissionChange("a-w")?.applied(to: 0o666, isDirectory: false) == 0o444)
        // X: execute for folders and for files someone may already execute.
        #expect(PermissionChange("a+X")?.applied(to: 0o644, isDirectory: false) == 0o644)
        #expect(PermissionChange("a+X")?.applied(to: 0o644, isDirectory: true) == 0o755)
        #expect(PermissionChange("a+X")?.applied(to: 0o744, isDirectory: false) == 0o755)
        for wrong in ["9", "75", "888", "rwxrwxrw", "rwxrwxrwz", "u+q", "z+r", "u"] {
            #expect(PermissionChange(wrong) == nil, "\(wrong)")
        }
    }

    // MARK: Date and time

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    @Test func partialDatesKeepTheOtherParts() throws {
        let original = try #require(
            utc.date(from: DateComponents(year: 2_026, month: 10, day: 11, hour: 9, minute: 58, second: 52)))
        func change(_ date: String, _ time: String) -> String? {
            guard let new = TimestampChange(date: date, time: time)?.applied(to: original, now: Date(), calendar: utc)
            else { return nil }
            let texts = TimestampChange.fieldTexts(for: new, calendar: utc)
            return texts.date + " " + texts.time
        }
        #expect(change("2020-01-02", "03:04:05") == "2020-01-02 03:04:05")
        #expect(change("yyyy-05-dd", "hh:mm:ss") == "2026-05-11 09:58:52")
        #expect(change("aaaa.05.aa", "xy.10.xy") == "2026-05-11 09:10:52")
        // Seconds left out become 0; an empty field keeps everything of its half.
        #expect(change("", "12:30") == "2026-10-11 12:30:00")
        #expect(change("2021/2/3", "") == "2021-02-03 09:58:52")
        #expect(change("2021-02-31", "") == nil)
        #expect(
            TimestampChange(date: "2021-13-01", time: "") == nil && TimestampChange(date: "2021-01", time: "") == nil)
        #expect(TimestampChange(date: "", time: "25:00") == nil && TimestampChange(date: "x-1-y", time: "") != nil)
        #expect(TimestampChange(date: "", time: "")?.changesNothing == true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(TimestampChange.current.applied(to: original, now: now) == now)
    }

    @Test func readsCommandParameters() throws {
        let parsed = try #require(AttributeChange.parse(parameters: "= +h -r +f +m640 +a -s +d2020-01-02 +t03:04"))
        #expect(
            parsed.applyAtOnce && parsed.change.hidden == true && parsed.change.locked == false && parsed.change.recurse
        )
        #expect(parsed.change.permissions == .absolute(0o640, keepingSpecialBits: false))
        #expect(parsed.change.timestamp?.parts == [2_020, 1, 2, 3, 4, 0])
        let dialog = try #require(AttributeChange.parse(parameters: "-h +mu+x"))
        #expect(!dialog.applyAtOnce && dialog.change.hidden == false && dialog.change.timestamp == nil)
        // `+c +t`: the current date, and the time as it is.
        let dateOnly = try #require(AttributeChange.parse(parameters: "=+c +t"))
        #expect(
            dateOnly.applyAtOnce && dateOnly.change.timestamp?.parts[0] != nil
                && dateOnly.change.timestamp?.parts[3] == nil)
        #expect(AttributeChange.parse(parameters: "+q") == nil && AttributeChange.parse(parameters: "h") == nil)
        #expect(AttributeChange.parse(parameters: "+m999") == nil && AttributeChange.parse(parameters: "+d2020") == nil)
        #expect(AttributeChange.parse(parameters: "")?.change.isEmpty == true)
    }

    // MARK: Links and reports

    @Test func relativeLinkPaths() {
        func path(_ from: String, _ to: String) -> String {
            LinkMaker.relativePath(from: URL(fileURLWithPath: from, isDirectory: true), to: URL(fileURLWithPath: to))
        }
        #expect(path("/a/b", "/a/b/file.txt") == "file.txt")
        #expect(path("/a/b", "/a/c/file.txt") == "../c/file.txt")
        #expect(path("/a/b/c", "/x") == "../../../x")
        #expect(path("/a/b", "/a/b") == ".")
    }

    @Test func spaceReportWording() {
        let small = SpaceReport.text(
            SpaceTotals(bytes: 23, allocated: 4_096, rounded: 4_096, files: 1), sourceIsLocal: true,
            targetCluster: 4_096,
            volume: VolumeInfo(name: "Disk", freeBytes: 2_048 * 1_024, totalBytes: 4_096 * 1_024), cancelled: false)
        #expect(
            small == """
                23 bytes in 1 file(s)

                Actual space used on source volume: 4,096 bytes
                Required on target volume: 4,096 bytes

                Disk: 2,048 k of 4,096 k free
                """)
        let large = SpaceReport.text(
            SpaceTotals(bytes: 23_332_990, files: 101, folders: 14, unreadable: 1), sourceIsLocal: false,
            targetCluster: nil,
            volume: nil, cancelled: true)
        #expect(large.hasPrefix("23,332,990 bytes in 101 file(s),\nin 14 directories\n(= 22,786 k, 22.25 M)"))
        #expect(
            large.contains("1 folder(s) could not be read") && large.contains("stopped")
                && !large.contains("Actual space"))
        #expect(
            SpaceCalculator.round(1, to: 4_096) == 4_096 && SpaceCalculator.round(4_096, to: 4_096) == 4_096
                && SpaceCalculator.round(0, to: 4_096) == 0)
        #expect(SpaceCalculator.round(5, to: nil) == 5)
    }
}

/// The parts that work on many files at once, run on all cores: these are the tests to run
/// under the thread sanitizer.
@Suite struct FilePropertiesSums {
    @Test func sizesNearTheEndOfTheRangeAddUpWithoutStoppingTheProgram() {
        // An archive may declare any size for a member.
        let huge = SpaceTotals(bytes: .max - 5, allocated: .max, rounded: .max - 1, files: 1)
        let sum = huge + SpaceTotals(bytes: 100, allocated: 100, rounded: 100, files: 1)
        #expect(sum.bytes == .max && sum.allocated == .max && sum.rounded == .max && sum.files == 2)
        #expect(SpaceCalculator.round(.max, to: 4_096) > 0 && SpaceCalculator.round(.max - 3, to: 4_096) > 0)
    }
}

@Suite struct FilePropertiesParallelWork {
    let fileSystems: FileSystemRegistry
    let memory: MemoryFileSystem

    init() {
        (fileSystems, memory) = makeFileSystems()
    }

    @Test func measuresATreeOnAllCores() throws {
        for folder in 0..<40 {
            for file in 0..<25 {
                memory.addFile("/tree/d\(folder)/sub\(file % 3)/f\(file).bin", String(repeating: "x", count: file))
            }
        }
        memory.addFile("/tree/top.bin", "12345")
        memory.addDirectory("/tree/empty")
        memory.unreadable = ["/tree/d0/sub0"]
        let tree = try #require(memory.item(at: memory.url("/tree")))
        let top = try #require(memory.item(at: memory.url("/tree/top.bin")))
        let totals = SpaceCalculator(fileSystems: fileSystems, targetCluster: 16).measure([tree, top])
        // 40 folders × 3 subfolders, the empty one and the tree itself.
        #expect(totals[0].folders == 40 * 4 + 2 && totals[0].unreadable == 1)
        let unreadableFiles = stride(from: 0, to: 25, by: 3).map { $0 }
        #expect(totals[0].files == 40 * 25 + 1 - unreadableFiles.count)
        let allBytes: Int = 40 * (0..<25).reduce(0, +) + 5
        let expectedBytes: Int = allBytes - unreadableFiles.reduce(0, +)
        #expect(totals[0].bytes == Int64(expectedBytes))
        #expect(
            totals[0].allocated == totals[0].bytes && totals[0].rounded >= totals[0].bytes
                && totals[0].rounded % 16 == 0)
        #expect(totals[1] == SpaceTotals(bytes: 5, allocated: 5, rounded: 16, files: 1))
        // A cancelled calculation stops descending.
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(
            SpaceCalculator(fileSystems: fileSystems, cancellation: cancelled).measure(directory: memory.url("/tree"))
                == SpaceTotals())
    }

    @Test func measuresRealAllocationOnTheLocalDisk() throws {
        let box = try Sandbox()
        try box.file("a/one.txt", String(repeating: "x", count: 5_000))
        try box.file("a/deep/two.txt", "2")
        try FileManager.default.createSymbolicLink(
            atPath: box.url("a/link").path, withDestinationPath: box.url("a/deep").path)
        let folder = try #require(fileSystems.item(at: box.url("a")))
        let totals = SpaceCalculator(fileSystems: fileSystems, targetCluster: LocalInfo.clusterSize(at: box.root))
            .measure([folder])[0]
        // The link is counted as a link, not followed.
        #expect(totals.files == 3 && totals.folders == 2 && totals.bytes == 5_001)
        #expect(totals.allocated >= 5_001 && totals.rounded >= 5_001 && totals.rounded % 512 == 0)
    }

    @Test func columnsAnswerFromManyThreadsAtOnce() throws {
        let box = try Sandbox()
        for index in 0..<60 { try box.file("f\(index).txt", String(repeating: "y", count: index)) }
        try box.file("descript.ion", (0..<60).map { "f\($0).txt comment \($0)\r\n" }.joined())
        try FileManager.default.createSymbolicLink(atPath: box.url("link").path, withDestinationPath: "f1.txt")
        memory.addFile("/m/a.png", "x")
        memory.addFile("/m/descript.ion", "a.png a picture\r\n")
        let columns = ColumnRegistry()
        PropertyColumns.register(in: columns, comments: CommentStore(fileSystems: fileSystems))
        #expect(
            columns.all.map(\.id) == [
                "comment", "owner", "group", "created", "accessed", "octal", "linkTarget", "kind", "tags", "xattrCount",
                "sizeOnDisk"
            ])
        let items =
            try fileSystems.provider(for: box.root).list(box.root, showHidden: true)
            + memory.list(memory.url("/m"), showHidden: true)
        // Every column for every item, all at once, as a panel asks.
        let cells = Parallel.map(items.flatMap { item in columns.all.map { (item, $0) } }) { item, column in
            (item.name, column.id, column.value(item))
        }
        func cell(_ name: String, _ column: String) -> String? { cells.first { $0.0 == name && $0.1 == column }?.2 }
        #expect(
            cell("f7.txt", "comment") == "comment 7" && cell("a.png", "comment") == "a picture"
                && cell("link", "comment") == "")
        #expect(cell("f7.txt", "owner") == NSUserName() && cell("a.png", "owner") == "")
        #expect(
            cell("f7.txt", "group")?.isEmpty == false && cell("f7.txt", "created")?.isEmpty == false
                && cell("f7.txt", "accessed")?.isEmpty == false)
        #expect(cell("f7.txt", "octal") == "644" && cell("a.png", "octal") == "644")
        #expect(cell("link", "linkTarget") == "f1.txt" && cell("f7.txt", "linkTarget") == "")
        #expect(cell("f7.txt", "kind")?.isEmpty == false && cell("a.png", "kind")?.isEmpty == false)
        #expect(cell("f7.txt", "tags") == "" && cell("a.png", "xattrCount") == "")
        let onDisk: String = cell("f59.txt", "sizeOnDisk") ?? ""
        let allocated: Int64 = Int64(onDisk.replacingOccurrences(of: ",", with: "")) ?? -1
        #expect(allocated >= 59)
    }

    @Test func commentStoreReadsAFolderOnceForManyReaders() throws {
        memory.addFile("/c/descript.ion", "a.txt first\r\nb.txt second\r\n")
        let store = CommentStore(fileSystems: fileSystems)
        let answers = Parallel.map(Array(0..<200)) { index in
            store.comments(in: memory.url("/c"))[index % 2 == 0 ? "a.txt" : "b.txt"]
        }
        #expect(answers.filter { $0 == "first" }.count == 100 && answers.filter { $0 == "second" }.count == 100)
        // A change made through the store is seen at once; the file disappears with its last comment.
        try store.setComment("changed", for: "A.TXT", in: memory.url("/c"), hidden: true)
        #expect(store.comments(in: memory.url("/c"))["a.txt"] == "changed")
        #expect(memory.contents("/c/descript.ion") == "a.txt changed\r\nb.txt second\r\n")
        try store.setComment("", for: "a.txt", in: memory.url("/c"), hidden: true)
        try store.setComment("", for: "b.txt", in: memory.url("/c"), hidden: true)
        #expect(!memory.exists("/c/descript.ion") && memory.allPaths == ["/c"])
    }

    @Test func changesAttributesOfATreeOnAllCores() throws {
        let box = try Sandbox()
        for folder in 0..<8 {
            for file in 0..<100 { try box.file("t/d\(folder)/f\(file).txt") }
        }
        let tree = try #require(fileSystems.item(at: box.url("t")))
        var change = AttributeChange()
        change.permissions = try #require(PermissionChange("go-r"))
        change.timestamp = TimestampChange(date: "2001-02-03", time: "04:05:06")
        change.recurse = true
        let outcome = AttributeJob(change: change, fileSystems: fileSystems).run([tree])
        #expect(outcome.changed == 8 * 100 + 8 + 1 && outcome.failed == 0 && !outcome.cancelled)
        let file = try #require(fileSystems.item(at: box.url("t/d3/f42.txt")))
        #expect(file.permissions == 0o600 && TimestampChange.fieldTexts(for: file.modified).date == "2001-02-03")
        #expect(fileSystems.item(at: box.url("t/d3"))?.permissions == 0o711)

        // Taking a folder's own permissions away does not lock the job out of its contents…
        change = AttributeChange(permissions: try #require(PermissionChange("000")), recurse: true)
        #expect(AttributeJob(change: change, fileSystems: fileSystems).run([tree]).failed == 0)
        // …and giving them back opens the folders on the way down.
        change.permissions = try #require(PermissionChange("u+rwX"))
        let restored = AttributeJob(change: change, fileSystems: fileSystems).run([tree])
        #expect(restored.failed == 0 && restored.changed == 809)
        #expect(
            fileSystems.item(at: box.url("t/d3/f42.txt"))?.permissions == 0o600
                && fileSystems.item(at: box.url("t/d3"))?.permissions == 0o700)
    }
}

/// The commands, driven through a kernel with fake panels.
@MainActor @Suite struct FilePropertiesCommands {
    let memory = MemoryFileSystem()
    let plugin = FilePropertiesPlugin(launchesApplications: false)
    let bench: TestBench
    let box: Sandbox

    var commands: CommandRegistry { bench.commands }
    var left: FakePanel { bench.left }
    var right: FakePanel { bench.right }
    var ui: ScriptedInteraction { bench.interaction }

    init() throws {
        box = try Sandbox()
        try box.file("A/one.txt", "12345")
        try box.file("A/two.txt", "2")
        try box.file("A/docs/in.txt", "inside")
        try box.file("A/docs/deep/more.txt", "more")
        try box.file("B/other.txt", "other", modified: Date(timeIntervalSince1970: 86_400 * 365))
        memory.addFile("/M/a.txt", "abc")
        memory.addFile("/M/sub/b.txt", "defgh")
        bench = TestBench(
            plugins: [plugin], fileSystems: [LocalFileSystem(), memory], left: box.url("A"), right: box.url("B"))
    }

    private func flags(_ path: String) -> UInt32 { LocalInfo.details(box.url(path))?.flags ?? 0 }
    private func mode(_ path: String) -> UInt16 { LocalInfo.details(box.url(path))?.mode ?? 0 }
    private func notes(_ form: [FormField]) -> [String] { form.map(\.label) }

    @Test func registersCommandsMenusKeysAndColumns() {
        let keys = bench.kernel.keyBindings
        #expect(keys.conflicts.isEmpty)
        #expect(
            keys.command(for: Shortcut(.returnKey, .option)) == .properties
                && keys.command(for: .cmd("i")) == .properties)
        #expect(keys.command(for: Shortcut(.character("l"), .control)) == .occupiedSpace)
        #expect(keys.command(for: Shortcut(.character("z"), .control)) == "cm_EditComment")
        #expect(keys.command(for: .f(5, [.control, .shift])) == "cm_CreateShortcut")
        let files = bench.kernel.menus.menus.first { $0.title == "Files" }?.items ?? []
        #expect(
            files == [
                .setAttributes, .properties, "afm_FinderInfo", .occupiedSpace, "cm_CountDirContent", "cm_EditComment",
                nil,
                "cm_CreateShortcut", "afm_ShowLinkTarget"
            ])
        #expect(files.compactMap { $0 }.allSatisfy { commands[$0] != nil })
        #expect(bench.kernel.columns["comment"] != nil && bench.kernel.columns.all.count == 11)
        #expect(bench.kernel.toolbar.defaultLayout.compactMap { $0?.command } == [.properties, .occupiedSpace])
        #expect(bench.kernel.preferences.pages.map(\.title) == ["File properties"])
    }

    // MARK: Change attributes

    @Test func changesPermissionsDateAndFlagsOfOneFile() {
        left.moveCursor(toName: "one.txt")
        ui.formAnswers = [
            .values([
                "permissions": .text("600"), "changeDate": .flag(true), "date": .text("2001-02-03"),
                "time": .text("hh:00"),
                "locked": .index(1)
            ])
        ]
        commands.perform(.setAttributes)
        #expect(ui.log.contains("form: Change attributes: one.txt"))
        // The dialog showed the file's own state.
        let form = ui.forms[0]
        #expect(form.first { $0.key == "permissions" }?.initialValue == .text("644"))
        if case .choice(let options, _)? = form.first(where: { $0.key == "hidden" })?.kind {
            #expect(options[0] == "Unchanged (not set)")
        }
        #expect(notes(form).contains { $0.hasPrefix("Owner (now \(NSUserName()))") })
        #expect(mode("A/one.txt") == 0o600 && flags("A/one.txt") & UInt32(UF_IMMUTABLE) != 0)
        let texts = TimestampChange.fieldTexts(for: left.model.items.first { $0.name == "one.txt" }?.modified ?? Date())
        #expect(texts.date == "2001-02-03" && texts.time.hasSuffix(":00:00"))

        // A locked file is unlocked before anything else is changed.
        ui.formAnswers = [.values(["permissions": .text("u+x"), "locked": .index(2), "hidden": .index(1)])]
        commands.perform(.setAttributes)
        #expect(mode("A/one.txt") == 0o700 && flags("A/one.txt") & UInt32(UF_IMMUTABLE) == 0)
        // Hidden now, so the panel no longer lists it.
        #expect(flags("A/one.txt") & UInt32(UF_HIDDEN) != 0 && left.names == ["docs", "two.txt"])
        #expect(!ui.log.contains { $0.hasPrefix("inform") })
    }

    @Test func changesSeveralItemsWithAndWithoutTheirContents() {
        left.model.selectAll()
        ui.formAnswers = [.values(["permissions": .text("go-r")])]
        commands.perform(.setAttributes)
        #expect(ui.log.contains("form: Change attributes: 3"))
        // Several items start unchanged: no permissions proposed, letters in the date fields.
        #expect(ui.forms[0].first { $0.key == "permissions" }?.initialValue == .text(""))
        #expect(ui.forms[0].first { $0.key == "date" }?.initialValue == .text("yyyy-mm-dd"))
        #expect(mode("A/one.txt") == 0o600 && mode("A/docs") == 0o711 && mode("A/docs/in.txt") == 0o644)
        ui.formAnswers = [.values(["permissions": .text("go-r"), "recurse": .flag(true), "current": .flag(true)])]
        commands.perform(.setAttributes)
        #expect(mode("A/docs/in.txt") == 0o600 && mode("A/docs/deep/more.txt") == 0o600 && mode("A/docs/deep") == 0o711)
        let changed = LocalInfo.details(box.url("A/docs/deep/more.txt"))?.modified ?? .distantPast
        #expect(abs(changed.timeIntervalSinceNow) < 60)
        // The selection the command started from can be brought back.
        #expect(left.model.savedSelection.count == 3)
    }

    @Test func wrongEntriesAreAskedAgainAndTargetFileCanBeLoaded() {
        left.moveCursor(toName: "two.txt")
        right.moveCursor(toName: "other.txt")
        ui.formAnswers = [
            .values(["permissions": .text("abc")]),
            .values(["permissions": .text(""), "changeDate": .flag(true), "date": .text("soon")]),
            .values([:], button: 1), .accept
        ]
        commands.perform(.setAttributes)
        #expect(ui.log.filter { $0.hasPrefix("form: Change attributes") }.count == 4)
        #expect(ui.log.contains("inform: The permissions \"abc\" cannot be read!"))
        #expect(ui.log.contains { $0.hasPrefix("inform: The date \"soon\"") })
        // What was typed is still there the second time; the target's values the fourth.
        #expect(ui.forms[1].first { $0.key == "permissions" }?.initialValue == .text("abc"))
        #expect(ui.forms[3].first { $0.key == "changeDate" }?.initialValue == .flag(true))
        let two = LocalInfo.details(box.url("A/two.txt"))?.modified
        #expect(two == Date(timeIntervalSince1970: 86_400 * 365))
        // Cancel changes nothing.
        ui.formAnswers = [.cancel]
        commands.perform(.setAttributes)
        #expect(mode("A/two.txt") == 0o644)
    }

    @Test func parametersApplyWithoutADialogAndFailuresAreReported() {
        left.moveCursor(toName: "two.txt")
        commands.perform(.setAttributes, .text("=+h +m640"))
        #expect(ui.forms.isEmpty && mode("A/two.txt") == 0o640 && flags("A/two.txt") & UInt32(UF_HIDDEN) != 0)
        commands.perform(.setAttributes, .text("+nonsense"))
        #expect(ui.log.last == "inform: The attribute parameters cannot be read!")
        // Without `=` the dialog opens with the parameters filled in.
        left.moveCursor(toName: "one.txt")
        ui.formAnswers = [.accept]
        commands.perform(.setAttributes, .text("+r +f +d2020-01-02"))
        let form = ui.forms[0]
        #expect(
            form.first { $0.key == "recurse" }?.initialValue == .flag(true)
                && form.first { $0.key == "locked" }?.initialValue == .index(1))
        #expect(
            form.first { $0.key == "date" }?.initialValue == .text("2020-01-02")
                && form.first { $0.key == "time" }?.initialValue == .text("hh:mm:ss"))
        #expect(flags("A/one.txt") & UInt32(UF_IMMUTABLE) != 0)
        commands.perform(.setAttributes, .text("=-r"))

        // A file system that cannot change attributes says so; flags are not offered there.
        left.show(memory.url("/M"))
        left.moveCursor(toName: "a.txt")
        ui.formAnswers = [.values(["permissions": .text("600")])]
        commands.perform(.setAttributes)
        #expect(ui.forms[1].allSatisfy { $0.key != "hidden" && $0.key != "owner" })
        #expect(ui.log.last == "inform: 1 item(s) could not be changed!")
        commands.perform(.setAttributes, .text("=+h"))
        #expect(ui.log.last == "inform: 1 item(s) could not be changed!")
        // On [..] there is nothing to change.
        left.model.moveCursor(to: 0)
        #expect(!commands.isEnabled(.setAttributes))
    }

    @Test func anUnknownOwnerIsRefused() {
        left.moveCursor(toName: "two.txt")
        ui.formAnswers = [.values(["owner": .text("no-such-user-afm")]), .values(["group": .text(String(getgid()))])]
        commands.perform(.setAttributes)
        #expect(ui.log.last == "inform: 1 item(s) could not be changed!")
        commands.perform(.setAttributes)
        #expect(ui.log.last?.hasPrefix("form:") == true && LocalInfo.details(box.url("A/two.txt"))?.groupID == getgid())
    }

    // MARK: Properties

    @Test func propertiesOfFilesFoldersAndSelections() throws {
        try box.file("A/descript.ion", "one.txt the first\r\n")
        left.moveCursor(toName: "one.txt")
        ui.formAnswers = [.accept]
        commands.perform(.properties)
        #expect(ui.log.last == "form: Properties: one.txt")
        var rows = notes(ui.forms[0])
        #expect(
            rows.contains("Name: one.txt") && rows.contains("Size: 5 bytes")
                && rows.contains("Permissions: rw-r--r-- (644)"))
        #expect(rows.contains("Where: \(box.url("A").path)") && rows.contains("Comment: the first"))
        #expect(
            rows.contains { $0.hasPrefix("Owner: \(NSUserName()) (") }
                && rows.contains { $0.hasPrefix("Size on disk: ") })
        for label in ["Kind", "Created", "Modified", "Accessed", "Group", "Volume"] {
            #expect(rows.contains { $0.hasPrefix(label + ": ") }, "\(label)")
        }
        #expect(plugin.finderInfoRequests.isEmpty)

        // A folder is counted with everything below it; the second button asks Finder.
        left.moveCursor(toName: "docs")
        ui.formAnswers = [.values([:], button: 1)]
        commands.perform(.properties)
        rows = notes(ui.forms[1])
        #expect(rows.contains("Size: 10 bytes") && rows.contains("Contains: 2 file(s), 1 folder(s)"))
        #expect(plugin.finderInfoRequests.map(\.path) == [box.url("A/docs").path])

        // On [..]: the folder the panel shows.
        left.model.moveCursor(to: 0)
        ui.formAnswers = [.accept]
        commands.perform(.properties)
        #expect(ui.log.last == "form: Properties: A" && notes(ui.forms[2]).contains("Contains: 5 file(s), 2 folder(s)"))

        // Several selected items are summed up.
        left.model.selectAll()
        ui.formAnswers = [.accept]
        commands.perform(.properties)
        rows = notes(ui.forms[3])
        #expect(ui.log.last == "form: Properties: 3 items" && rows.contains("Contains: 4 file(s), 2 folder(s)"))
        #expect(rows.contains("Items: 3: docs, one.txt, two.txt"))
    }

    @Test func propertiesAndFinderInfoElsewhere() {
        left.show(memory.url("/M"))
        left.moveCursor(toName: "sub")
        ui.formAnswers = [.accept]
        commands.perform(.properties)
        let rows = notes(ui.forms[0])
        #expect(rows.contains("Size: 5 bytes") && rows.contains("Where: mem:/M") && rows.contains("Volume: Memory"))
        #expect(!rows.contains { $0.hasPrefix("Owner") || $0.hasPrefix("Size on disk") })
        // No Finder for what is not on the Mac's disks.
        #expect(!commands.isEnabled("afm_FinderInfo"))
        left.show(box.url("A"))
        left.moveCursor(toName: "two.txt")
        commands.perform("afm_FinderInfo")
        #expect(plugin.finderInfoRequests.map(\.path) == [box.url("A/two.txt").path])
    }

    // MARK: Occupied space

    @Test func occupiedSpaceMeasuresTheOperandsAndShowsFolderSizes() {
        left.moveCursor(toName: "docs")
        commands.perform(.occupiedSpace)
        #expect(
            ui.log.last == "inform: Total space occupied:" && bench.jobService.titles == ["Calculating occupied space:"]
        )
        #expect(left.model.items.first { $0.name == "docs" }?.computedSize == 10 && left.model.selection == ["docs"])
        // With a selection, the selection is measured, not the cursor item.
        left.model.clearSelection()
        left.model.toggleSelection(row: left.model.row(ofName: "one.txt") ?? -1)
        commands.perform(.occupiedSpace)
        #expect(left.model.selection == ["one.txt"])
        // The preference keeps measured folders unselected.
        bench.kernel.settings.set(false, forKey: "fileProperties.selectMeasuredFolders")
        left.show(memory.url("/M"))
        left.moveCursor(toName: "sub")
        commands.perform(.occupiedSpace)
        #expect(left.model.items.first { $0.name == "sub" }?.computedSize == 5 && left.model.selection.isEmpty)
        left.model.moveCursor(to: 0)
        #expect(!commands.isEnabled(.occupiedSpace))
    }

    @Test func allFolderSizesAtOnce() throws {
        try box.file("A/more/x.bin", "1234567")
        left.reload()
        commands.perform("cm_CountDirContent")
        #expect(left.model.items.filter(\.isFolder).map(\.computedSize) == [10, 7] && left.model.selection.isEmpty)
        #expect(!ui.log.contains { $0.hasPrefix("inform") })
    }

    // MARK: Comments

    @Test func editsCommentsInTheFoldersCommentFile() {
        bench.kernel.columns["comment"].map { left.extraColumns = [$0.id] }
        left.moveCursor(toName: "one.txt")
        ui.formAnswers = [.values(["comment": .text("first line\nsecond line")])]
        commands.perform("cm_EditComment")
        #expect(ui.log.contains("form: File comment"))
        let bytes = FileManager.default.contents(atPath: box.url("A/descript.ion").path)
        #expect(bytes == Data("one.txt first line\\nsecond line".utf8) + Data([0x04, 0xC2, 0x0D, 0x0A]))
        // The new comment file is hidden, so the list stays as it was.
        #expect(flags("A/descript.ion") & UInt32(UF_HIDDEN) != 0 && left.names == ["docs", "one.txt", "two.txt"])
        let column = bench.kernel.columns["comment"]
        #expect(left.model.cursorItem.map { column?.value($0) } == "first line second line")

        // The dialog shows the comment that is there; an unchanged or cancelled dialog writes nothing.
        ui.formAnswers = [.accept, .cancel, .values(["comment": .text("")])]
        commands.perform("cm_EditComment")
        commands.perform("cm_EditComment")
        #expect(
            ui.forms[1].first?.initialValue == .text("first line\nsecond line")
                && bench.jobService.titles.filter { $0 == "Saving comment:" }.count == 1)
        // An empty comment removes the entry, and the file with its last entry.
        commands.perform("cm_EditComment")
        #expect(!box.exists("A/descript.ion") && left.model.cursorItem.map { column?.value($0) } == "")
    }

    @Test func commentsWorkOnAnyWritableFileSystemAndForTheFolderItself() {
        left.show(memory.url("/M/sub"))
        // On [..] the comment belongs to the folder the panel shows and lives one level up.
        left.model.moveCursor(to: 0)
        ui.formAnswers = [.values(["comment": .text("a folder")])]
        commands.perform("cm_EditComment")
        #expect(memory.contents("/M/descript.ion") == "sub a folder\r\n")
        left.moveCursor(toName: "b.txt")
        ui.formAnswers = [
            .values(["comment": .text(String(repeating: "x", count: 5_000))]), .values(["comment": .text("größer")])
        ]
        commands.perform("cm_EditComment")
        #expect(
            ui.log.contains("inform: The comment is too long!")
                && ui.log.filter { $0 == "form: File comment" }.count == 3)
        #expect(memory.allPaths.filter { $0.contains("descript") } == ["/M/descript.ion", "/M/sub/descript.ion"])
        memory.capabilities = []
        #expect(!commands.isEnabled("cm_EditComment"))
    }

    // MARK: Links

    @Test func createsSymbolicLinksAliasesAndHardLinks() throws {
        left.moveCursor(toName: "one.txt")
        ui.formAnswers = [.accept]
        commands.perform("cm_CreateShortcut")
        #expect(
            ui.log.last == "form: Create link"
                && ui.forms[0].first?.initialValue == .text(box.url("B").path + "/one.txt"))
        #expect(LocalInfo.linkTarget(box.url("B/one.txt")) == box.url("A/one.txt").path)
        #expect(right.names == ["one.txt", "other.txt"] && right.model.cursorItem?.name == "one.txt")

        // Another name, relative, and the other kinds of link.
        ui.formAnswers = [
            .values(["target": .text(box.url("B").path + "/rel.txt"), "relative": .flag(true)]),
            .values(["target": .text(box.url("B").path + "/hard.txt"), "kind": .index(LinkKind.hard.rawValue)]),
            .values(["target": .text(box.url("B").path + "/alias"), "kind": .index(LinkKind.alias.rawValue)])
        ]
        for _ in 0..<3 { commands.perform("cm_CreateShortcut") }
        #expect(LocalInfo.linkTarget(box.url("B/rel.txt")) == "../A/one.txt" && box.read("B/rel.txt") == "12345")
        #expect(LocalInfo.details(box.url("A/one.txt"))?.linkCount == 2 && box.read("B/hard.txt") == "12345")
        #expect(
            LocalInfo.resolvedLinkTarget(box.url("B/alias"))?.resolvingSymlinksInPath().path
                == box.url("A/one.txt").path)

        // An existing name is never replaced; several operands go into the folder under their names.
        ui.formAnswers = [.accept]
        commands.perform("cm_CreateShortcut")
        #expect(ui.log.last == "inform: 1 link(s) could not be created!")
        left.model.selectAll()
        ui.formAnswers = [.values(["target": .text(box.url("B/links").path)])]
        try box.folder("B/links")
        commands.perform("cm_CreateShortcut")
        #expect(namesOnDisk(box.url("B/links")) == ["docs", "one.txt", "two.txt"])
        #expect(ui.forms.last?.first?.initialValue == .text(box.url("B").path + "/"))
        // Only the Mac's own file system has links.
        left.show(memory.url("/M"))
        left.moveCursor(toName: "a.txt")
        #expect(!commands.isEnabled("cm_CreateShortcut") && !commands.isEnabled("afm_ShowLinkTarget"))
    }

    @Test func goesToTheTargetOfALink() throws {
        try FileManager.default.createSymbolicLink(
            atPath: box.url("A/to-more").path, withDestinationPath: "docs/deep/more.txt")
        left.reload()
        left.moveCursor(toName: "to-more")
        commands.perform("afm_ShowLinkTarget")
        #expect(left.model.directory.path == box.url("A/docs/deep").path && left.model.cursorItem?.name == "more.txt")
        commands.perform("afm_ShowLinkTarget")
        #expect(ui.log.last == "inform: more.txt is not a link.")
    }
}
