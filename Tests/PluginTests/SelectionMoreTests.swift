import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import SelectionPlugin

/// The pure parts of the Mark menu: masks, selection types, selection files and the
/// comparison of two lists.
@Suite struct SelectionMoreRules {
    func matching(_ mask: String, _ names: [String], folders: Set<String> = []) -> [String] {
        let mask = SelectionMask(mask)
        return zip(names, mask.selected(names.map { MaskEntry(name: $0, isFolder: folders.contains($0)) })).filter(\.1)
            .map(\.0)
    }

    @Test func wildcardsIncludesAndExcludes() {
        let names = ["win.ini", "Write.exe", "notes.bak", "w.old", "README", "long name.txt", ".cvs", "src"]
        let folders: Set = [".cvs", "src"]
        #expect(matching("*.*", names, folders: folders) == names)
        #expect(matching("w*.*|*.bak *.old", names) == ["win.ini", "Write.exe"])
        #expect(matching("|*.exe", names).count == names.count - 1)
        #expect(matching("*.ini;*.EXE", names) == ["win.ini", "Write.exe"])
        #expect(matching("*.", names, folders: folders) == ["README", "src"])
        #expect(matching("readme.*", names) == ["README"])
        #expect(matching("\"long name.txt\" w.???", names) == ["w.old", "long name.txt"])
        #expect(matching("?.old", names) == ["w.old"])
        // A trailing separator means folders, in either notation.
        #expect(matching("*.* | .cvs\\", names, folders: folders) == names.filter { $0 != ".cvs" })
        #expect(matching("*.* | */", names, folders: folders) == names.filter { !folders.contains($0) })
        #expect(matching("s*/", names + ["s.txt"], folders: folders) == ["src"])
        #expect(matching("", names).isEmpty == false)
    }

    @Test func regularExpressions() {
        let names = ["alpha.txt", "Beta.txt", "gamma.md"]
        #expect(matching("<^(a|b)", names) == ["alpha.txt", "Beta.txt"])
        #expect(matching("<\\.md$", names) == ["gamma.md"])
        #expect(!SelectionMask("<(").isValid && matching("<(", names).isEmpty)
    }

    @Test func relatedFiles() {
        let names = ["IMG_1057.JPG", "IMG_1057.CR2", "CRW_1057.CR2", "IMG_2000.CR2", "notes.txt"]
        #expect(matching("*.jpg>*.cr2", names) == ["IMG_1057.JPG", "IMG_1057.CR2"])
        #expect(matching("*.jpg>crw*.cr2", names) == ["IMG_1057.JPG", "CRW_1057.CR2"])
        #expect(
            Wildcard.rename("report.txt", with: "*.bak") == "report.bak"
                && Wildcard.rename("abc.txt", with: "x?*.*") == "xbc.txt"
        )
        // Related files are looked for in the same folder only.
        let mask = SelectionMask("*.jpg>*.cr2")
        let entries = [
            MaskEntry(name: "a.jpg", directory: ["one"]), MaskEntry(name: "a.cr2", directory: ["two"]),
            MaskEntry(name: "a.cr2", directory: ["one"])
        ]
        #expect(mask.selected(entries) == [true, false, true])
    }

    @Test func pathLimitedMasks() {
        func matches(_ mask: String, _ name: String, in directory: [String]) -> Bool {
            SelectionMask(mask).matches(MaskEntry(name: name, directory: directory))
        }
        #expect(matches("\\*.txt", "a.txt", in: []) && !matches("\\*.txt", "a.txt", in: ["sub"]))
        #expect(
            matches("/sub1/sub2/*.txt", "a.txt", in: ["sub1", "sub2"])
                && !matches("/sub1/sub2/*.txt", "a.txt", in: ["x", "sub1", "sub2"])
        )
        #expect(
            matches("sub1\\sub2\\*.txt", "a.txt", in: ["x", "sub1", "sub2"])
                && !matches("sub1\\sub2\\*.txt", "a.txt", in: ["sub1"])
        )
        #expect(
            matches("subdir/**/*.txt", "test.txt", in: ["subdir", "subdir2", "subdir3"])
                && matches("subdir/**/*.txt", "test.txt", in: ["subdir"])
        )
        #expect(!matches("subdir/**/*.txt", "test.txt", in: ["other"]))
        #expect(SelectionMask("a/*.txt").needsDirectories && !SelectionMask("*.txt|*.bak").needsDirectories)
    }

    @Test func rulesReadPathsRelativeToTheListsDirectory() {
        let base = URL(string: "mem:///work")!
        func item(_ path: String) -> FileItem {
            let url = URL(string: "mem:///work/" + path)!
            return FileItem(url: url, name: path.replacingOccurrences(of: "/", with: "-"), isDirectory: false)
        }
        let items = [item("a.txt"), item("sub/b.txt"), item("sub/deep/c.txt")]
        #expect(SelectionRule(mask: "/*.txt").names(among: items, base: base) == ["a.txt"])
        #expect(
            SelectionRule(mask: "sub/**/*.txt").names(among: items, base: base) == ["sub-b.txt", "sub-deep-c.txt"]
        )
        #expect(SelectionRule(mask: "deep/*.txt").names(among: items, base: base) == ["sub-deep-c.txt"])
    }

    @Test func selectionTypes() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func file(_ name: String, size: Int64, daysOld: Double, hidden: Bool = false, folder: Bool = false) -> FileItem
        {
            FileItem(
                url: URL(fileURLWithPath: "/x/" + name),
                name: name,
                isDirectory: folder,
                isHidden: hidden,
                size: size,
                modified: now.addingTimeInterval(-daysOld * 86_400)
            )
        }
        let items = [
            file("small.txt", size: 10, daysOld: 1), file("big.txt", size: 5_000, daysOld: 40),
            file("big.md", size: 9_000, daysOld: 2),
            file(".secret.txt", size: 2_000, daysOld: 0.5, hidden: true),
            file("dir.txt", size: 0, daysOld: 0, folder: true)
        ]
        var type = SelectionType(name: "big", mask: "*.txt")
        type.minSize = 1_024
        #expect(
            SelectionRule(type).names(among: items, base: URL(fileURLWithPath: "/x"), now: now) == [
                "big.txt", ".secret.txt"
            ]
        )
        type.notOlderThanDays = 7
        type.hidden = .no
        #expect(SelectionRule(type).names(among: items, base: URL(fileURLWithPath: "/x"), now: now).isEmpty)
        var recent = SelectionType(name: "recent")
        recent.kind = .folders
        #expect(SelectionRule(recent).names(among: items, base: URL(fileURLWithPath: "/x"), now: now) == ["dir.txt"])
        recent.kind = .files
        recent.modifiedFrom = now.addingTimeInterval(-3 * 86_400)
        recent.modifiedTo = now.addingTimeInterval(-86_400)
        recent.maxSize = 9_000
        #expect(
            SelectionRule(recent).names(among: items, base: URL(fileURLWithPath: "/x"), now: now) == [
                "small.txt", "big.md"
            ]
        )

        #expect(
            SelectionType.size(from: "10k") == 10_240 && SelectionType.size(from: "1.5 M") == 1_572_864
                && SelectionType.size(from: "12") == 12
        )
        #expect(
            SelectionType.size(from: "big") == nil && SelectionType.text(ofSize: 10_240) == "10k"
                && SelectionType.text(ofSize: 1_500) == "1500"
        )
        let day = SelectionType.date(from: "2026-10-11")
        #expect(
            day != nil && SelectionType.date(from: "2026-10-11", endOfDay: true) == day?.addingTimeInterval(86_399)
        )
        #expect(
            SelectionType.date(from: SelectionType.text(ofDate: day)) == day
                && SelectionType.date(from: "tomorrow") == nil
        )
        let data = try? JSONEncoder().encode(type)
        #expect(data.flatMap { try? JSONDecoder().decode(SelectionType.self, from: $0) } == type)
    }

    @Test func selectionFiles() {
        let items = [
            FileItem(url: URL(fileURLWithPath: "/x/dir1"), name: "dir1", isDirectory: true),
            FileItem(url: URL(fileURLWithPath: "/x/ro.txt"), name: "ro.txt", isDirectory: false),
            FileItem(url: URL(fileURLWithPath: "/x/sél.txt"), name: "sél.txt", isDirectory: false)
        ]
        let unicode = SelectionFile.encode(items, as: .unicode)
        #expect(Array(unicode.prefix(8)) == [0xFF, 0xFE, 0x64, 0, 0x69, 0, 0x72, 0])
        #expect(SelectionFile.text(from: unicode) == "dir1\\\r\nro.txt\r\nsél.txt")
        let ansi = SelectionFile.encode(items, as: .ansi)
        #expect(ansi.count == "dir1\\\r\nro.txt\r\nsél.txt".unicodeScalars.count && ansi.contains(0xE9))
        #expect(SelectionFile.text(from: ansi) == "dir1\\\r\nro.txt\r\nsél.txt")
        #expect(SelectionFile.text(from: Data([0xEF, 0xBB, 0xBF]) + Data("a\nb".utf8)) == "a\nb")
        #expect(SelectionFile.text(from: Data([0xFE, 0xFF, 0, 0x61])) == "a")

        let known: Set = ["dir1", "ro.txt", "sél.txt", "odd\\"]
        #expect(SelectionFile.names(in: "dir1\\\r\nro.txt\r\nmissing.txt", among: known) == ["dir1", "ro.txt"])
        #expect(
            SelectionFile.names(in: "/x/dir1/\n/x/sél.txt\nodd\\\n", among: known) == ["dir1", "sél.txt", "odd\\"]
        )
        #expect(SelectionFile.names(in: "", among: known).isEmpty)
    }

    @Test func comparingTwoLists() {
        func file(_ name: String, _ size: Int64, _ time: TimeInterval) -> FileItem {
            FileItem(
                url: URL(fileURLWithPath: "/x/" + name),
                name: name,
                isDirectory: false,
                size: size,
                modified: Date(timeIntervalSince1970: time)
            )
        }
        func folder(_ name: String) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, isDirectory: true)
        }
        let left = [
            file("same", 1, 100), file("newer", 1, 200.9), file("older", 1, 100), file("size", 1, 100),
            file("onlyLeft", 1, 1),
            file("hour", 1, 3_700), folder("both"), folder("leftDir"), file("kind", 1, 1)
        ]
        let right = [
            file("same", 1, 100.4), file("newer", 1, 100), file("older", 2, 200), file("size", 2, 100),
            file("onlyRight", 1, 1),
            file("hour", 1, 100), folder("both"), folder("rightDir"), folder("kind")
        ]
        typealias Marks = DirectoryComparison.Marks
        #expect(
            DirectoryComparison.compare(left: left, right: right, mode: .newerOrDifferent)
                == Marks(
                    left: ["newer", "size", "onlyLeft", "hour", "kind"],
                    right: ["older", "size", "onlyRight"],
                    same: ["same", "both"]
                )
        )
        #expect(
            DirectoryComparison.compare(left: left, right: right, mode: .newer)
                == Marks(
                    left: ["newer", "onlyLeft", "hour", "kind"],
                    right: ["older", "onlyRight"],
                    same: ["same", "both"]
                )
        )
        #expect(
            DirectoryComparison.compare(left: left, right: right, mode: .missing, withSubdirectories: true)
                == Marks(
                    left: ["onlyLeft", "kind", "leftDir"],
                    right: ["onlyRight", "rightDir", "kind"],
                    same: ["same", "both"]
                )
        )
        #expect(
            DirectoryComparison.compare(left: left, right: right, mode: .sizeOrMissing)
                == Marks(
                    left: ["older", "size", "onlyLeft", "kind"],
                    right: ["older", "size", "onlyRight"],
                    same: ["same", "both"]
                )
        )
        let lenient = DirectoryComparison.compare(left: left, right: right, mode: .newer, ignoringOneHour: true)
        #expect(!lenient.left.contains("hour") && lenient.same.contains("hour"))
    }
}

/// The Mark commands driven through a kernel with fake panels and an in-memory file system.
@MainActor @Suite struct SelectionMoreCommands {
    typealias Ids = SelectionCommands

    let memory = MemoryFileSystem()
    private let scratch = ScratchPasteboard()
    var pasteboard: NSPasteboard { scratch.pasteboard }
    let settings = MemorySettings()

    init() {
        let (old, new) = (Date(timeIntervalSince1970: 1_000_000), Date(timeIntervalSince1970: 2_000_000))
        memory.addFile("/A/docs/in.txt")
        memory.addDirectory("/A/shared")
        memory.addFile("/A/one.txt", "new", modified: new)
        memory.addFile("/A/two.txt", "2", modified: old)
        memory.addFile("/A/two.md", "2", modified: old)
        memory.addFile("/A/three.md", "333", modified: old)
        memory.addFile("/A/big.bin", String(repeating: "x", count: 4_096), modified: old)
        memory.addDirectory("/B/shared")
        memory.addDirectory("/B/extra")
        memory.addFile("/B/one.txt", "old", modified: old)
        memory.addFile("/B/two.txt", "2", modified: old)
        memory.addFile("/B/three.md", "3", modified: old)
        memory.addFile("/B/only_b.txt", "b", modified: old)
    }

    func makeBench() -> TestBench {
        TestBench(
            plugins: [SelectionPlugin(pasteboard: pasteboard, background: false)],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/A"),
            right: memory.url("/B"),
            settings: settings
        )
    }

    func data(_ path: String) -> Data {
        guard let reader = try? memory.read(memory.url(path)) else { return Data() }
        return (try? reader.read(upToCount: 1 << 20)) ?? Data()
    }

    @Test func registration() {
        let bench = makeBench()
        let keys = bench.kernel.keyBindings
        #expect(bench.kernel.keyClashes.isEmpty)
        #expect(keys.command(for: .f(2, .shift)) == Ids.compareDirectories)
        #expect(keys.command(for: Shortcut(.keypadPlus, .option)) == Ids.selectCurrentExtension)
        #expect(keys.command(for: Shortcut(.keypadMinus, .option)) == Ids.unselectCurrentExtension)
        #expect(keys.command(for: Shortcut(.keypadMinus, .shift)) == Ids.clearFiles)
        #expect(keys.command(for: Shortcut(.keypadMultiply)) == .invertSelection && keys.command(for: .cmd("i")) == nil)
        let menus = bench.kernel.menus.menus
        #expect(menus.map(\.title) == ["Mark"])
        #expect(menus[0].items.compactMap { $0 }.allSatisfy { bench.commands[$0] != nil })
        #expect(
            menus[0].items.contains(Ids.loadSelectionFromClipboard) && menus[0].items.contains(Ids.markNewerHideSame)
        )
        #expect(bench.kernel.preferences.pages.map(\.title) == ["Selection"])
        let proposed = bench.kernel.toolbar.defaultLayout.compactMap { $0 }.map(\.command)
        #expect(proposed == [.selectGroup, .unselectGroup, .invertSelection, Ids.compareDirectories])
    }

    @Test func groupsByMask() {
        let bench = makeBench()
        let (commands, left) = (bench.commands, bench.left)
        commands.perform(.selectGroup, .text("*.txt *.md | two.*"))
        #expect(left.model.selection == ["one.txt", "three.md"])
        commands.perform(.selectGroup, .text("<^(docs|big)"))
        #expect(left.model.selection == ["one.txt", "three.md", "docs", "big.bin"])
        commands.perform(.unselectGroup, .text("*.*|*.md"))
        #expect(left.model.selection == ["three.md"])
        commands.perform(Ids.selectFiles, .text("*.*"))
        #expect(left.model.selection == ["one.txt", "two.txt", "two.md", "three.md", "big.bin"])
        commands.perform(Ids.clearFiles, .text("two.*"))
        commands.perform(Ids.selectFolders, .text("s*"))
        #expect(left.model.selection == ["one.txt", "three.md", "big.bin", "shared"])
        commands.perform(.unselectAll)
        commands.perform(.selectGroup, .text("two.txt>*.md"))
        #expect(left.model.selection == ["two.txt", "two.md"])
        // The dialog proposes *.*, or the extension under the cursor.
        left.moveCursor(toName: "three.md")
        bench.ui.promptAnswers = [.accept]
        commands.perform(Ids.selectGroupCurrentExtension)
        #expect(
            left.model.selection == ["two.txt", "two.md", "three.md"]
                && bench.ui.log.last == "prompt: Expand selection [*.md]"
        )
        bench.ui.promptAnswers = [.cancel]
        commands.perform(Ids.clearFolders)
        #expect(left.model.selection.count == 3)
        commands.perform(.selectGroup, .text("<("))
        #expect(
            bench.ui.log.last == "inform: The regular expression cannot be read." && left.model.selection.count == 3
        )
    }

    @Test func foldersAsConfigured() {
        settings.set(false, forKey: "selection.markDirectories")
        let bench = makeBench()
        let (commands, left) = (bench.commands, bench.left)
        commands.perform(.selectAll)
        #expect(left.model.selection == ["one.txt", "two.txt", "two.md", "three.md", "big.bin"])
        commands.perform(Ids.selectAllOtherChoice)
        #expect(left.model.selection.count == 7)
        commands.perform(.invertSelection)
        #expect(left.model.selection == ["docs", "shared"])
        commands.perform(Ids.invertOtherChoice)
        #expect(left.model.selection == ["one.txt", "two.txt", "two.md", "three.md", "big.bin"])
        commands.perform(Ids.invertFolders)
        commands.perform(Ids.clearAllFiles)
        #expect(left.model.selection == ["docs", "shared"])
        commands.perform(.selectGroup, .text("*"))
        commands.perform(Ids.clearAllFolders)
        #expect(left.model.selection.count == 5)
        commands.perform(Ids.selectGroupOtherChoice, .text("d*"))
        #expect(left.model.selection.contains("docs"))
        commands.perform(.unselectAll)
        #expect(left.model.selection.isEmpty)
        commands.perform(Ids.selectAllFolders)
        commands.perform(Ids.selectAllBoth)
        #expect(left.model.selection.count == 7)
    }

    @Test func everyNthLineAndSteps() {
        let bench = makeBench()
        let (commands, left) = (bench.commands, bench.left)
        let files = left.names.filter { !["docs", "shared"].contains($0) }
        left.moveCursor(toName: files[1])
        commands.perform(Ids.selectAllFiles, .index(2))
        #expect(left.model.selection == [files[1], files[3]])
        commands.perform(Ids.clearAllFiles, .index(-1))
        #expect(left.model.selection == [files[3]])
        commands.perform(.unselectAll)

        left.moveCursor(toName: left.names[0])
        let start = left.model.cursor
        commands.perform(Ids.select, .index(3))
        #expect(left.model.selection == Set(left.names.prefix(3)) && left.model.cursor == start + 3)
        commands.perform(Ids.unselect, .index(-2))
        #expect(left.model.selection == Set(left.names.prefix(2)) && left.model.cursor == start + 1)
        commands.perform(Ids.select)
        #expect(left.model.selection == Set(left.names.prefix(2)) && left.model.cursor == start + 2)
    }

    @Test func likeTheItemUnderTheCursor() {
        let bench = makeBench()
        let (commands, left) = (bench.commands, bench.left)
        left.moveCursor(toName: "two.md")
        commands.perform(Ids.selectCurrentExtension)
        #expect(left.model.selection == ["two.md", "three.md"])
        commands.perform(Ids.selectCurrentName)
        #expect(left.model.selection == ["two.md", "three.md", "two.txt"])
        commands.perform(Ids.unselectCurrentExtension)
        #expect(left.model.selection == ["two.txt"])
        commands.perform(Ids.unselectCurrentName)
        commands.perform(Ids.selectCurrentNameAndExtension)
        #expect(left.model.selection == ["two.md"])
        commands.perform(Ids.selectCurrentPath)
        #expect(left.model.selection.count == 7)
        commands.perform(Ids.unselectCurrentPath)
        #expect(left.model.selection.isEmpty)
        // A folder has no extension to go by.
        left.moveCursor(toName: "docs")
        commands.perform(Ids.selectCurrentExtension)
        #expect(left.model.selection.isEmpty)
        left.model.moveCursor(to: 0)
        #expect(left.model.cursorIsOnParentRow && !commands.isEnabled(Ids.selectCurrentExtension))
    }

    @Test func historyAndSelectionTypes() {
        let bench = makeBench()
        let (commands, left, ui) = (bench.commands, bench.left, bench.ui)
        commands.perform(Ids.selectFromList)
        #expect(ui.log.last == "inform: There are no saved selection types or earlier masks yet.")
        commands.perform(.selectGroup, .text("*.md"))
        commands.perform(.unselectGroup, .text("*.*"))
        commands.perform(.selectGroup, .text("*.md"))
        commands.perform(.unselectAll)

        // Define a type: files of at least 1k.
        ui.formAnswers = [
            .values(["name": .text("large"), "mask": .text("*.*"), "kind": .index(1), "minSize": .text("1k")])
        ]
        commands.perform(Ids.defineSelectionType)
        commands.perform(.selectGroup, .text(">Large"))
        #expect(left.model.selection == ["big.bin"])
        commands.perform(.selectGroup, .text(">nothing"))
        #expect(ui.log.last == "inform: There is no selection type called nothing.")

        // The list holds the types first, then the masks, newest first.
        ui.formAnswers = [.values(["row": .index(1)], button: 0)]
        commands.perform(Ids.selectFromList)
        if case .list(let rows, _)? = ui.forms.last?.first?.kind {
            #expect(rows == [">large", "*.md", "*.*"])
        } else {
            Issue.record("no list")
        }
        #expect(left.model.selection == ["big.bin", "two.md", "three.md"])
        ui.formAnswers = [.values(["row": .index(0)], button: 1)]
        commands.perform(Ids.selectFromList)
        #expect(left.model.selection == ["two.md", "three.md"])
        ui.formAnswers = [.values(["row": .index(2)], button: 2)]
        commands.perform(Ids.selectFromList)

        // A second plugin instance reads the same settings: types and history persist.
        let again = makeBench()
        again.ui.formAnswers = [.cancel]
        again.commands.perform(Ids.selectFromList)
        if case .list(let rows, _)? = again.ui.forms.last?.first?.kind {
            #expect(rows == [">large", "*.md"])
        } else {
            Issue.record("no list")
        }

        // Editing: the type is picked, changed and refused when a field cannot be read.
        ui.formAnswers = [.values(["row": .index(0)]), .values(["name": .text("small"), "maxSize": .text("lots")])]
        commands.perform(Ids.defineSelectionType)
        #expect(ui.log.last == "inform: The selection type was not saved.")
        ui.formAnswers = [
            .values(["row": .index(0)]),
            .values(["name": .text("small"), "maxSize": .text("3"), "from": .text("1970-01-02")])
        ]
        commands.perform(Ids.defineSelectionType)
        commands.perform(.unselectAll)
        commands.perform(.selectGroup, .text(">small"))
        #expect(left.model.selection == ["one.txt", "two.txt", "two.md", "three.md"])
        ui.formAnswers = [.values(["row": .index(2)]), .values([:], button: 1)]
        commands.perform(Ids.defineSelectionType)
        commands.perform(.selectGroup, .text(">small"))
        #expect(ui.log.last == "inform: There is no selection type called small.")
    }

    @Test func savingAndLoadingSelectionFiles() {
        let bench = makeBench()
        let (commands, left, ui) = (bench.commands, bench.left, bench.ui)
        commands.perform(.selectGroup, .text("docs *.md"))
        ui.promptAnswers = [.text("sel")]
        commands.perform(Ids.saveSelectionToFile)
        #expect(bench.jobService.titles == ["Saving selection:"])
        let saved = data("/A/sel.txt")
        #expect(
            saved.starts(with: [0xFF, 0xFE])
                && Set(SelectionFile.text(from: saved).components(separatedBy: "\r\n")) == [
                    "docs\\", "two.md", "three.md"
                ]
        )
        // The panel shows the new file and keeps its selection.
        #expect(left.names.contains("sel.txt") && left.model.selection == ["docs", "two.md", "three.md"])

        commands.perform(Ids.saveSelection)
        commands.perform(.selectAll)
        ui.promptAnswers = [.text("sel.txt")]
        commands.perform(Ids.loadSelectionFromFile)
        #expect(left.model.selection == ["docs", "two.md", "three.md"])
        commands.perform(.unselectAll)
        commands.perform(.restoreSelection)
        #expect(left.model.selection == ["docs", "two.md", "three.md"])

        // ANSI, to a full path, over an existing file only after a question.
        commands.perform(.unselectAll)
        left.moveCursor(toName: "one.txt")
        commands.perform(Ids.saveSelectionToFileANSI, .text("mem:/B/list.txt"))
        #expect(memory.contents("/B/list.txt") == "one.txt" && bench.right.names.contains("list.txt"))
        left.moveCursor(toName: "two.txt")
        commands.perform(Ids.saveSelectionToFileANSI, .location(memory.url("/B/list.txt")))
        #expect(
            memory.contents("/B/list.txt") == "one.txt"
                && ui.log.last == "choose: mem:/B/list.txt already exists. / Do you want to overwrite it?"
        )
        ui.choiceAnswers = [0]
        commands.perform(Ids.saveSelectionToFileUnicode, .location(memory.url("/B/list.txt")))
        #expect(SelectionFile.text(from: data("/B/list.txt")) == "two.txt")
        commands.perform(Ids.loadSelectionFromFile, .location(memory.url("/B/list.txt")))
        #expect(left.model.selection == ["two.txt"])

        commands.perform(Ids.loadSelectionFromFile, .text("missing.txt"))
        #expect(ui.log.last == "inform: The selection cannot be loaded!" && left.model.selection == ["two.txt"])
        ui.promptAnswers = [.cancel]
        commands.perform(Ids.saveSelectionToFile)
        #expect(!memory.exists("/A/.txt"))
    }

    @Test func selectionFilesOnTheLocalDisk() throws {
        let box = try Sandbox()
        try box.file("A/alpha.txt")
        try box.file("A/beta.txt")
        try box.folder("A/sub")
        try box.folder("B")
        let bench = makeBench()
        bench.left.show(box.url("A"))
        bench.commands.perform(.selectGroup, .text("alpha.* sub"))
        bench.commands.perform(Ids.saveSelectionToFile, .text("../B/chosen"))
        let written = try Data(contentsOf: box.url("B/chosen.txt"))
        #expect(SelectionFile.text(from: written) == "sub\\\r\nalpha.txt")
        bench.commands.perform(.invertSelection)
        #expect(bench.left.model.selection == ["beta.txt"])
        bench.commands.perform(Ids.loadSelectionFromFile, .text(box.url("B/chosen.txt").path))
        #expect(bench.left.model.selection == ["alpha.txt", "sub"])
    }

    @Test func loadingFromTheClipboard() {
        let bench = makeBench()
        let (commands, left) = (bench.commands, bench.left)
        pasteboard.clearContents()
        commands.perform(Ids.loadSelectionFromClipboard)
        #expect(left.model.selection.isEmpty)
        pasteboard.setString("mem:/A/docs/\nmem:/A/one.txt\r\ntwo.md\nelsewhere.txt", forType: .string)
        commands.perform(.selectGroup, .text("big.bin"))
        commands.perform(Ids.loadSelectionFromClipboard)
        #expect(left.model.selection == ["docs", "one.txt", "two.md"])
    }

    @Test func comparingDirectories() {
        let bench = makeBench()
        let (commands, left, right) = (bench.commands, bench.left, bench.right)
        // The previous selection is replaced on both sides.
        right.model.selectAll()
        commands.perform(Ids.compareDirectories)
        #expect(
            left.model.selection == ["one.txt", "two.md", "big.bin", "three.md"]
                && right.model.selection == ["only_b.txt", "three.md"]
        )
        commands.perform(Ids.compareDirectories, .index(1))
        #expect(left.model.selection == ["two.md", "big.bin"] && right.model.selection == ["only_b.txt"])
        commands.perform(Ids.compareDirectories, .index(2))
        #expect(
            left.model.selection == ["two.md", "big.bin", "three.md"]
                && right.model.selection == ["only_b.txt", "three.md"]
        )
        commands.perform(Ids.compareDirectoriesWithSubdirectories, .index(1))
        #expect(
            left.model.selection == ["two.md", "big.bin", "docs"] && right.model.selection == ["only_b.txt", "extra"]
        )
        // Both panels on the same folder: nothing differs.
        right.show(memory.url("/A"))
        commands.perform(Ids.compareDirectories)
        #expect(left.model.selection.isEmpty && right.model.selection.isEmpty)
    }

    @Test func markNewerHideSame() {
        let bench = makeBench()
        let (commands, left, right) = (bench.commands, bench.left, bench.right)
        commands.perform(Ids.markNewerHideSame)
        #expect(
            left.model.filter?.title == "Comparison: mem:/A/*.*"
                && right.model.filter?.title == "Comparison: mem:/B/*.*"
        )
        #expect(
            Set(left.names) == ["docs", "one.txt", "two.md", "three.md", "big.bin"]
                && Set(right.names) == ["extra", "one.txt", "three.md", "only_b.txt"]
        )
        // Same time but another size: shown, not marked.
        #expect(left.model.selection == ["one.txt", "two.md", "big.bin"] && right.model.selection == ["only_b.txt"])
        #expect(commands.isChecked(Ids.markNewerHideSame) && memory.exists("/A/two.txt"))
        // Choosing it again shows everything.
        commands.perform(Ids.markNewerHideSame)
        #expect(
            left.model.filter == nil && right.model.filter == nil && left.names.count == 7
                && !commands.isChecked(Ids.markNewerHideSame)
        )

        // The view ends when the panel goes elsewhere; the other panel keeps it.
        commands.perform(Ids.markNewerHideSame)
        left.show(memory.url("/A/docs"))
        bench.kernel.panelEvents.post(.locationChanged, from: left)
        #expect(left.model.filter == nil && left.names == ["in.txt"] && right.model.filter != nil)
        bench.kernel.panelEvents.post(.locationChanged, from: right)
        #expect(right.model.filter != nil)
    }

    @Test func aLargeListIsSelectedWithFewAnnouncements() {
        for index in 0..<3_000 { memory.addFile("/big/file\(index).\(index % 2 == 0 ? "txt" : "md")") }
        let bench = makeBench()
        bench.left.show(memory.url("/big"))
        var announcements = 0
        bench.left.model.onChange = { _ in announcements += 1 }
        bench.commands.perform(.selectGroup, .text("*.txt"))
        #expect(bench.left.model.selection.count == 1_500 && announcements <= 2)
        announcements = 0
        bench.commands.perform(.unselectGroup, .text("file1*"))
        #expect(bench.left.model.selection.count == 1_500 - 555 && announcements == 1)
    }
}
