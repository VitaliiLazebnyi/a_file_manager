import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// Runs on a file system in memory and on the local disk, and the conflicts they meet.
extension MultiRenameRuns {
    // MARK: Runs

    /// A run renames the items, empties the list and remembers the mask, without a message.
    @Test
    internal func renamesAndEmptiesTheList() {
        let session = open(["IMG_*"])
        session.settings.nameMask = "Photo_[C:2]"
        session.settings.letterCase = .upper
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.renamed.count == 3 && result?.failures.isEmpty == true)
        #expect(photos == ["PHOTO_01.JPG", "PHOTO_02.JPG", "PHOTO_03.JPG", "notes.txt"])
        #expect(memory.contents("/photos/PHOTO_02.JPG") == "p1")
        // No message; the list is empty and the panel shows the new names.
        #expect(session.rows.isEmpty && !interaction.log.contains { $0.hasPrefix("inform") })
        #expect(left.names.sorted() == ["PHOTO_01.JPG", "PHOTO_02.JPG", "PHOTO_03.JPG", "notes.txt"])
        #expect(session.canUndo && session.hasResultList)
        #expect(bench.jobService.titles == ["Multi-Rename:"])
        #expect(RenameStore(settings: settings).history(.nameMask) == ["Photo_[C:2]"])
    }

    /// Items whose name does not change stay in the list.
    @Test
    internal func unchangedItemsStayInTheList() {
        let session = open()
        session.settings.search = "IMG_"
        session.settings.replacement = "pic"
        session.start(completion: nil)
        #expect(photos == ["notes.txt", "pic1001.jpg", "pic1002.jpg", "pic1003.jpg"])
        #expect(session.rows.map(\.entry.name) == ["notes.txt"])
    }

    /// A run writes the result log, which is shown in a form when there is no viewer.
    @Test
    internal func resultLog() throws {
        let session = open(["IMG_1001.jpg", "IMG_1002.jpg"])
        session.settings.nameMask = "[C]/pic"
        session.start(completion: nil)
        let log = try String(contentsOf: box.url("log/renlog.txt"), encoding: .utf8)
        #expect(log == "\"mem:/photos/IMG_1001.jpg\" -> \"1/pic.jpg\"\n\"mem:/photos/IMG_1002.jpg\" -> \"2/pic.jpg\"\n")
        #expect(session.logURL == box.url("log/renlog.txt"))
        // Without a viewer the log is shown in a form.
        interaction.formAnswers = [.accept]
        session.showResultList()
        #expect(interaction.log.last == "form: Result list")
    }

    /// Slashes in the new names move the items into folders that are made; Undo leaves those.
    @Test
    internal func slashesMoveIntoFoldersThatAreCreated() {
        let session = open(["IMG_*"])
        session.settings.nameMask = "[C+1/2]/[N]"
        session.start(completion: nil)
        #expect(
            memory.allPaths.filter { $0.hasPrefix("/photos/") && $0.hasSuffix(".jpg") }
                == ["/photos/1/IMG_1001.jpg", "/photos/1/IMG_1002.jpg", "/photos/2/IMG_1003.jpg"]
        )
        interaction.choiceAnswers = [0]
        session.undo(completion: nil)
        // Undo puts the files back and leaves the folders.
        #expect(photos == ["1", "2", "IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"])
    }

    /// Given names can swap and shift names, through temporary ones that do not stay; Undo puts them back.
    @Test
    internal func swapsAndShiftsThroughGivenNames() {
        let session = open(["IMG_*"])
        session.loadNames(fromText: "IMG_1002.jpg\r\nIMG_1003.jpg\r\nIMG_1001.jpg\r\n")
        #expect(session.givenNames.count == 3 && session.rows.allSatisfy { $0.status == .ready })
        session.start(completion: nil)
        #expect(photos == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"])
        #expect(
            ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg"].map { memory.contents("/photos/" + $0) } == [
                "p2", "p0", "p1"
            ]
        )
        #expect(!memory.allPaths.contains { $0.contains("afm-rename") })
        interaction.choiceAnswers = [0]
        session.undo(completion: nil)
        #expect(
            ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg"].map { memory.contents("/photos/" + $0) } == [
                "p0", "p1", "p2"
            ]
        )
        #expect(!memory.allPaths.contains { $0.contains("afm-rename") })
    }

    /// A counter that shifts every name by one works on the local disk, and so does its Undo.
    @Test
    internal func counterShiftOnTheLocalDisk() throws {
        for index in 1...4 {
            try box.file("A/\(index).txt", "content \(index)")
        }
        left.show(box.url("A"))
        let session = open()
        session.settings.nameMask = "[C2]"
        #expect(
            names(session) == ["2.txt", "3.txt", "4.txt", "5.txt"] && session.rows.allSatisfy { $0.status == .ready }
        )
        session.start(completion: nil)
        #expect(namesOnDisk(box.url("A")) == ["2.txt", "3.txt", "4.txt", "5.txt"])
        #expect((2...5).map { box.read("A/\($0).txt") } == ["content 1", "content 2", "content 3", "content 4"])
        interaction.choiceAnswers = [0]
        session.undo(completion: nil)
        #expect(namesOnDisk(box.url("A")) == ["1.txt", "2.txt", "3.txt", "4.txt"])
        #expect(box.read("A/1.txt") == "content 1" && box.read("A/4.txt") == "content 4")
    }

    /// A swap and a rename that changes only the letter case work on the local disk, and are undone.
    @Test
    internal func swapAndCaseOnlyRenameOnTheLocalDisk() throws {
        try box.file("A/one.txt", "1")
        try box.file("A/two.txt", "2")
        try box.file("A/readme.md", "r")
        left.show(box.url("A"))
        let session = open()
        #expect(session.rows.map(\.entry.name) == ["one.txt", "readme.md", "two.txt"])
        session.loadNames(fromText: "two.txt\nREADME.md\none.txt")
        #expect(session.rows.allSatisfy { $0.status == .ready })
        session.start(completion: nil)
        #expect(namesOnDisk(box.url("A")) == ["README.md", "one.txt", "two.txt"])
        #expect(box.read("A/one.txt") == "2" && box.read("A/two.txt") == "1" && box.read("A/README.md") == "r")
        interaction.choiceAnswers = [0]
        session.undo(completion: nil)
        #expect(namesOnDisk(box.url("A")) == ["one.txt", "readme.md", "two.txt"])
        #expect(box.read("A/one.txt") == "1" && box.read("A/two.txt") == "2")
    }

    /// Names put all in upper case are renamed on a local disk that does not tell case apart.
    @Test
    internal func allUppercaseOnTheLocalDisk() throws {
        try box.file("A/a.txt", "a")
        try box.file("A/b.txt", "b")
        left.show(box.url("A"))
        let session = open()
        session.settings.letterCase = .upper
        #expect(session.rows.allSatisfy { $0.status == .ready })
        session.start(completion: nil)
        #expect(namesOnDisk(box.url("A")) == ["A.TXT", "B.TXT"] && box.read("A/A.TXT") == "a")
    }

    // MARK: Conflicts

    /// Conflicts are renamed away to numbered names when the user says so.
    @Test
    internal func conflictsAreAutoRenamedWhenAsked() {
        let session = open(["IMG_*"])
        session.settings.nameMask = "notes"
        session.settings.extensionMask = "txt"
        interaction.choiceAnswers = [0]
        session.start(completion: nil)
        #expect(photos == ["notes (2).txt", "notes (3).txt", "notes (4).txt", "notes.txt"])
        #expect(memory.contents("/photos/notes.txt") == "n" && memory.contents("/photos/notes (2).txt") == "p0")
        #expect(interaction.log.contains { $0.hasPrefix("choose: Name conflict: 3 file(s)") })
    }

    /// Conflicts can cancel the run or be skipped, the skipped items staying in the list.
    @Test
    internal func conflictsCanBeSkippedOrCancelTheRun() {
        let session = open()
        session.settings.search = "IMG_1001.jpg|IMG_1002"
        session.settings.replacement = "notes.txt|pic"
        // Cancel: nothing happens.
        session.start(completion: nil)
        #expect(photos == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"] && !session.canUndo)
        interaction.choiceAnswers = [1]
        session.start(completion: nil)
        #expect(photos == ["IMG_1001.jpg", "IMG_1003.jpg", "notes.txt", "pic.jpg"])
        #expect(session.rows.map(\.entry.name) == ["IMG_1001.jpg", "IMG_1003.jpg", "notes.txt"])
    }

    /// A file that appears after the preview is found by the run and not overwritten.
    @Test
    internal func aFileThatAppearsMeanwhileIsNotOverwritten() {
        let session = open(["IMG_1001.jpg", "IMG_1002.jpg"])
        session.settings.nameMask = "new[C]"
        // After the preview, behind the tool's back; the run finds it and asks.
        memory.addFile("/photos/new2.jpg", "other")
        interaction.choiceAnswers = [1]
        session.start(completion: nil)
        #expect(memory.contents("/photos/new2.jpg") == "other" && memory.contents("/photos/new1.jpg") == "p0")
        #expect(memory.exists("/photos/IMG_1002.jpg"))
    }

    /// What could not be renamed is reported and stays in the list.
    @Test
    internal func failuresAreReportedAndStayInTheList() throws {
        try box.file("A/a.txt", "a")
        try box.file("A/b.txt", "b")
        try box.file("A/keep.txt", "k")
        left.show(box.url("A"))
        let session = open(["a.txt", "b.txt"])
        // The name of an existing file as a folder: nothing can be created below it.
        session.loadNames(fromText: "x.txt\nkeep.txt/inside.txt")
        // Names that come from a list and put a file into another folder are asked about first.
        interaction.choiceAnswers = [0]
        var result: RenameRunResult?
        session.start { result = $0 }
        #expect(result?.renamed.count == 1 && result?.failures.count == 1)
        #expect(namesOnDisk(box.url("A")) == ["b.txt", "keep.txt", "x.txt"])
        #expect(session.rows.map(\.entry.name) == ["b.txt"])
        #expect(interaction.log.contains("inform: 1 file(s) could not be renamed!"))
    }
}
