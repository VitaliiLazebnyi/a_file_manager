import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import SelectionPlugin

/// The pure parts of the Mark menu: masks, selection types, selection files and the
/// comparison of two lists.
@Suite
internal struct SelectionMoreRules {
    /// The names a mask selects among `names`, of which `folders` are folders.
    internal func matching(_ mask: String, _ names: [String], folders: Set<String>) -> [String] {
        let selection = SelectionMask(mask)
        let entries = names.map { MaskEntry(name: $0, isFolder: folders.contains($0)) }
        return zip(names, selection.selected(entries) { false }).filter(\.1).map(\.0)
    }

    /// Two lists to compare: the left one with newer, older, bigger and missing entries.
    internal func lists() -> (left: [FileItem], right: [FileItem]) {
        func file(_ name: String, _ size: Int64, _ time: TimeInterval) -> FileItem {
            FileItem(
                url: URL(fileURLWithPath: "/x/" + name),
                name: name,
                stat: .init(size: size, modified: Date(timeIntervalSince1970: time))
            )
        }
        func folder(_ name: String) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/x/" + name), name: name, kind: .directory)
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
        return (left, right)
    }

    /// Wildcards, several masks, excluded masks, quoted names and masks that mean folders.
    @Test
    internal func wildcardsIncludesAndExcludes() {
        let names = ["win.ini", "Write.exe", "notes.bak", "w.old", "README", "long name.txt", ".cvs", "src"]
        let folders: Set = [".cvs", "src"]
        #expect(matching("*.*", names, folders: folders) == names)
        #expect(matching("w*.*|*.bak *.old", names, folders: []) == ["win.ini", "Write.exe"])
        #expect(matching("|*.exe", names, folders: []).count == names.count - 1)
        #expect(matching("*.ini;*.EXE", names, folders: []) == ["win.ini", "Write.exe"])
        #expect(matching("*.", names, folders: folders) == ["README", "src"])
        #expect(matching("readme.*", names, folders: []) == ["README"])
        #expect(matching("\"long name.txt\" w.???", names, folders: []) == ["w.old", "long name.txt"])
        #expect(matching("?.old", names, folders: []) == ["w.old"])
        // A trailing separator means folders, in either notation.
        #expect(matching("*.* | .cvs\\", names, folders: folders) == names.filter { $0 != ".cvs" })
        #expect(matching("*.* | */", names, folders: folders) == names.filter { !folders.contains($0) })
        #expect(matching("s*/", names + ["s.txt"], folders: folders) == ["src"])
        #expect(matching("", names, folders: []).isEmpty == false)
    }

    /// A mask with a leading `<` is a regular expression; one that cannot be read selects nothing.
    @Test
    internal func regularExpressions() {
        let names = ["alpha.txt", "Beta.txt", "gamma.md"]
        #expect(matching("<^(a|b)", names, folders: []) == ["alpha.txt", "Beta.txt"])
        #expect(matching("<\\.md$", names, folders: []) == ["gamma.md"])
        #expect(!SelectionMask("<(").isValid && matching("<(", names, folders: []).isEmpty)
    }

    /// `A>B` also takes the files of the same folder whose names the rename mask makes.
    @Test
    internal func relatedFiles() {
        let names = ["IMG_1057.JPG", "IMG_1057.CR2", "CRW_1057.CR2", "IMG_2000.CR2", "notes.txt"]
        #expect(matching("*.jpg>*.cr2", names, folders: []) == ["IMG_1057.JPG", "IMG_1057.CR2"])
        #expect(matching("*.jpg>crw*.cr2", names, folders: []) == ["IMG_1057.JPG", "CRW_1057.CR2"])
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
        #expect(mask.selected(entries) { false } == [true, false, true])
    }

    /// Masks with a folder part match the folders leading to the entry, anchored or not.
    @Test
    internal func pathLimitedMasks() {
        func matches(_ mask: String, _ name: String, in directory: [String]) -> Bool {
            SelectionMask(mask).matches(MaskEntry(name: name, directory: directory)) { false }
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

    /// A rule reads the folders of the entries of a gathered list relative to the list's directory.
    @Test
    internal func rulesReadPathsRelativeToTheListsDirectory() throws {
        let base = try #require(URL(string: "mem:///work"))
        func item(_ path: String) -> FileItem {
            FileItem(url: base.appending(path: path), name: path.replacingOccurrences(of: "/", with: "-"))
        }
        let items = [item("a.txt"), item("sub/b.txt"), item("sub/deep/c.txt")]
        let now = Date()
        #expect(SelectionRule(mask: "/*.txt").names(among: items, base: base, now: now) == ["a.txt"])
        #expect(
            SelectionRule(mask: "sub/**/*.txt").names(among: items, base: base, now: now)
                == ["sub-b.txt", "sub-deep-c.txt"]
        )
        #expect(SelectionRule(mask: "deep/*.txt").names(among: items, base: base, now: now) == ["sub-deep-c.txt"])
    }

    /// A selection type adds conditions on kind, size, dates, age and the hidden flag to its mask.
    @Test
    internal func selectionTypes() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func file(
            _ name: String,
            size: Int64,
            daysOld: Double,
            hidden: Bool = false,
            folder: Bool = false
        ) -> FileItem {
            FileItem(
                url: URL(fileURLWithPath: "/x/" + name),
                name: name,
                kind: .init(isDirectory: folder, isHidden: hidden),
                stat: .init(size: size, modified: now.addingTimeInterval(-daysOld * 86_400))
            )
        }
        let items = [
            file("small.txt", size: 10, daysOld: 1), file("big.txt", size: 5_000, daysOld: 40),
            file("big.md", size: 9_000, daysOld: 2),
            file(".secret.txt", size: 2_000, daysOld: 0.5, hidden: true),
            file("dir.txt", size: 0, daysOld: 0, folder: true)
        ]
        let base = URL(fileURLWithPath: "/x")
        var type = SelectionType(name: "big", mask: "*.txt")
        type.minSize = 1_024
        #expect(SelectionRule(type).names(among: items, base: base, now: now) == ["big.txt", ".secret.txt"])
        type.notOlderThanDays = 7
        type.hidden = .excluded
        #expect(SelectionRule(type).names(among: items, base: base, now: now).isEmpty)
        var recent = SelectionType(name: "recent")
        recent.kind = .folders
        #expect(SelectionRule(recent).names(among: items, base: base, now: now) == ["dir.txt"])
        recent.kind = .files
        recent.modifiedFrom = now.addingTimeInterval(-3 * 86_400)
        recent.modifiedTo = now.addingTimeInterval(-86_400)
        recent.maxSize = 9_000
        #expect(SelectionRule(recent).names(among: items, base: base, now: now) == ["small.txt", "big.md"])
        let data = try? JSONEncoder().encode(type)
        #expect(data.flatMap { try? JSONDecoder().decode(SelectionType.self, from: $0) } == type)
    }

    /// The dialog's texts of sizes and dates read and write the values they stand for.
    @Test
    internal func selectionTypeTexts() {
        #expect(
            SelectionType.size(from: "10k") == 10_240 && SelectionType.size(from: "1.5 M") == 1_572_864
                && SelectionType.size(from: "12") == 12
        )
        #expect(
            SelectionType.size(from: "big") == nil && SelectionType.text(ofSize: 10_240) == "10k"
                && SelectionType.text(ofSize: 1_500) == "1500"
        )
        let day = SelectionType.date(from: "2026-10-11", endOfDay: false)
        #expect(
            day != nil && SelectionType.date(from: "2026-10-11", endOfDay: true) == day?.addingTimeInterval(86_399)
        )
        #expect(
            SelectionType.date(from: SelectionType.text(ofDate: day), endOfDay: false) == day
                && SelectionType.date(from: "tomorrow", endOfDay: false) == nil
        )
    }

    /// Selection files are written in UTF-16 or Windows-1252 and read in any encoding, with paths.
    @Test
    internal func selectionFiles() {
        let items = [
            FileItem(url: URL(fileURLWithPath: "/x/dir1"), name: "dir1", kind: .directory),
            FileItem(url: URL(fileURLWithPath: "/x/ro.txt"), name: "ro.txt"),
            FileItem(url: URL(fileURLWithPath: "/x/sél.txt"), name: "sél.txt")
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

    /// Newer, missing and differing entries are marked as each mode says; folders are the same.
    @Test
    internal func comparingTwoLists() {
        let (left, right) = lists()
        typealias Marks = DirectoryComparison.Marks
        #expect(
            DirectoryComparison.compare(left: left, right: right, options: .init(mode: .newerOrDifferent))
                == Marks(
                    left: ["newer", "size", "onlyLeft", "hour", "kind"],
                    right: ["older", "size", "onlyRight"],
                    same: ["same", "both"]
                )
        )
        #expect(
            DirectoryComparison.compare(left: left, right: right, options: .init(mode: .newer))
                == Marks(
                    left: ["newer", "onlyLeft", "hour", "kind"],
                    right: ["older", "onlyRight"],
                    same: ["same", "both"]
                )
        )
    }

    /// Missing folders are marked with subdirectories, sizes in that mode, and an hour can count as none.
    @Test
    internal func comparingTwoListsByOtherModes() {
        let (left, right) = lists()
        typealias Marks = DirectoryComparison.Marks
        #expect(
            DirectoryComparison.compare(
                left: left,
                right: right,
                options: .init(mode: .missing, withSubdirectories: true)
            )
                == Marks(
                    left: ["onlyLeft", "kind", "leftDir"],
                    right: ["onlyRight", "rightDir", "kind"],
                    same: ["same", "both"]
                )
        )
        #expect(
            DirectoryComparison.compare(left: left, right: right, options: .init(mode: .sizeOrMissing))
                == Marks(
                    left: ["older", "size", "onlyLeft", "kind"],
                    right: ["older", "size", "onlyRight"],
                    same: ["same", "both"]
                )
        )
        let lenient = DirectoryComparison.compare(
            left: left,
            right: right,
            options: .init(mode: .newer, ignoringOneHour: true)
        )
        #expect(!lenient.left.contains("hour") && lenient.same.contains("hour"))
    }
}
