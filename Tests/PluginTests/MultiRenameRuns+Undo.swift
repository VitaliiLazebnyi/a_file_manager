import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// Undo, the order of the list, the names from a list and the saved settings.
extension MultiRenameRuns {
    // MARK: Undo

    /// Undo asks first and puts the names back in reverse order.
    @Test
    internal func undoAsksAndRestoresInReverseOrder() {
        let session = open(["IMG_*"])
        session.settings.nameMask = "Photo_[C]"
        session.start(completion: nil)
        // No: nothing happens.
        session.undo(completion: nil)
        #expect(photos.contains("Photo_1.jpg") && session.canUndo)
        #expect(
            interaction.log.last
                == "choose: Test / Undo the following rename action:\nIMG_1001.jpg -> Photo_1.jpg\n"
                + "IMG_1002.jpg -> Photo_2.jpg\nIMG_1003.jpg -> Photo_3.jpg"
        )
        interaction.choiceAnswers = [0]
        var answered = false
        var remaining: [RenamedItem] = []
        session.undo { notBack in
            (answered, remaining) = (true, notBack)
        }
        #expect(
            answered && remaining.isEmpty && photos == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"]
        )
        #expect(!session.canUndo && !session.hasResultList)
        #expect(bench.left.names == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"])
    }

    /// Undo works after the tool was closed, run by run, and keeps what could not be put back.
    @Test
    internal func undoWorksAfterTheToolWasClosedAndKeepsWhatFailed() {
        var session = open(["IMG_*"])
        session.settings.nameMask = "a[C]"
        session.start(completion: nil)
        session = open(["notes.txt"])
        session.settings.nameMask = "b"
        session.start(completion: nil)
        #expect(RenameStore(settings: settings).undoHistory.map(\.count) == [3, 1])
        // Another program takes one of the old names.
        memory.addFile("/photos/IMG_1002.jpg", "taken")
        // A new session, as after reopening the tool: the runs are undone one by one.
        session = open(["b.txt"])
        interaction.choiceAnswers = [0, 0]
        session.undo(completion: nil)
        #expect(memory.exists("/photos/notes.txt") && session.canUndo)
        var answered = false
        var remaining: [RenamedItem] = []
        session.undo { notBack in
            (answered, remaining) = (true, notBack)
        }
        #expect(answered && remaining.map(\.destination.lastPathComponent) == ["a2.jpg"])
        #expect(photos == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "a2.jpg", "notes.txt"])
        #expect(memory.contents("/photos/IMG_1002.jpg") == "taken")
        #expect(RenameStore(settings: settings).undoHistory.map(\.count) == [1])
        #expect(interaction.log.contains("inform: 1 file(s) could not be renamed back!"))
    }

    /// The undo history keeps as many runs as the preference says, and none at 0.
    @Test
    internal func undoHistoryIsLimited() {
        settings.set("2", forKey: RenameStore.undoLimitKey)
        for round in 1...3 {
            let session = open(["notes*"])
            session.settings.nameMask = "notes\(round)"
            session.start(completion: nil)
        }
        #expect(RenameStore(settings: settings).undoHistory.count == 2)
        settings.set("0", forKey: RenameStore.undoLimitKey)
        let session = open(["notes*"])
        session.settings.nameMask = "final"
        session.start(completion: nil)
        #expect(photos.contains("final.txt") && !session.canUndo)
    }

    // MARK: The list

    /// Sorting, moving and removing rows change the order, which drives the counter.
    @Test
    internal func orderDrivesTheCounter() {
        let session = open()
        session.settings.nameMask = "[C]"
        #expect(names(session) == ["1.jpg", "2.jpg", "3.jpg", "4.txt"])
        session.sort(by: .name, ascending: false)
        #expect(session.rows.map(\.entry.name) == ["notes.txt", "IMG_1003.jpg", "IMG_1002.jpg", "IMG_1001.jpg"])
        #expect(names(session) == ["1.txt", "2.jpg", "3.jpg", "4.jpg"])
        session.sort(by: .ext, ascending: true)
        #expect(session.rows.map(\.entry.name) == ["IMG_1001.jpg", "IMG_1002.jpg", "IMG_1003.jpg", "notes.txt"])
        session.sort(by: .date, ascending: false)
        #expect(session.rows.map(\.entry.name).prefix(2) == ["IMG_1003.jpg", "IMG_1002.jpg"])
        session.sort(by: .size, ascending: true)
        #expect(session.rows.first?.entry.name == "notes.txt")
        session.sort(by: .name, ascending: true)
        #expect(session.move([1], by: -1) == [0])
        #expect(
            session.rows.map(\.entry.name).prefix(2) == ["IMG_1002.jpg", "IMG_1001.jpg"]
                && names(session).first == "1.jpg"
        )
        #expect(session.move([0], by: -1) == [0] && session.move([3], by: 1) == [3])
        #expect(session.move([0, 1], by: 1) == [1, 2])
        #expect(session.rows.map(\.entry.name) == ["IMG_1003.jpg", "IMG_1002.jpg", "IMG_1001.jpg", "notes.txt"])
        #expect(session.move([3, 0], to: 2) == [1, 2])
        #expect(session.rows.map(\.entry.name) == ["IMG_1002.jpg", "IMG_1003.jpg", "notes.txt", "IMG_1001.jpg"])
        session.remove([0, 2])
        #expect(
            session.rows.map(\.entry.name) == ["IMG_1003.jpg", "IMG_1001.jpg"] && names(session) == ["1.jpg", "2.jpg"]
        )
        session.start(completion: nil)
        #expect(
            memory.contents("/photos/1.jpg") == "p2" && memory.contents("/photos/2.jpg") == "p0"
                && memory.exists("/photos/IMG_1002.jpg")
        )
    }

    /// "Next step" makes the computed names the old names of the next rules, renaming nothing yet.
    @Test
    internal func nextStepChainsRules() {
        let session = open(["IMG_*"])
        session.settings.search = "IMG_"
        session.settings.replacement = "holiday "
        session.nextStep()
        // Nothing is renamed yet; the computed names are the old names of the next rules.
        #expect(photos.contains("IMG_1001.jpg") && session.settings == .unchanged)
        #expect(session.rows.map(\.entry.name) == ["holiday 1001.jpg", "holiday 1002.jpg", "holiday 1003.jpg"])
        #expect(session.rows.allSatisfy { $0.status == .ready })
        session.settings.nameMask = "[F][N1-7]-[N-1]"
        session.start(completion: nil)
        #expect(photos == ["Holiday-1.jpg", "Holiday-2.jpg", "Holiday-3.jpg", "notes.txt"])
    }

    /// Names are edited as text or loaded from a file; a list that cannot be read is reported.
    @Test
    internal func editNamesAndLoadNamesFromAFile() throws {
        let session = open(["IMG_*"])
        session.settings.nameMask = "[N]x"
        interaction.formAnswers = [.values(["names": .text("first.jpg\nsecond.jpg")])]
        session.editNames()
        if case .multilineText(let proposed)? = interaction.forms.last?.first?.kind {
            #expect(proposed == "IMG_1001x.jpg\nIMG_1002x.jpg\nIMG_1003x.jpg")
        } else {
            Issue.record("the names are edited in a text field")
        }
        // A shorter list leaves the rest to the masks; the case conversion still applies.
        session.settings.letterCase = .upper
        #expect(names(session) == ["FIRST.JPG", "SECOND.JPG", "IMG_1003X.JPG"])
        session.clearGivenNames()
        #expect(names(session).first == "IMG_1001X.JPG")
        interaction.formAnswers = [.cancel]
        session.editNames()
        #expect(session.givenNames.isEmpty)

        session.settings = .unchanged
        let list = try box.file("names.txt", "a.jpg\nb.jpg\nc.jpg\n")
        var loaded = false
        session.loadNames(from: list) { loaded = true }
        #expect(loaded && names(session) == ["a.jpg", "b.jpg", "c.jpg"])
        session.loadNames(from: memory.addFile("/lists/utf16.txt", "ignored"), completion: nil)
        session.loadNames(from: box.url("missing.txt"), completion: nil)
        #expect(interaction.log.last == "inform: The names cannot be loaded!")
        // Sorting ends the pairing of names and places.
        session.sort(by: .name, ascending: false)
        #expect(session.givenNames.isEmpty)
    }

    // MARK: Settings

    /// Settings are saved under trimmed names, loaded and deleted, and the tool opens with the last or the chosen ones.
    @Test
    internal func savedSettings() {
        var session = open(["IMG_*"])
        session.settings.nameMask = "[N]_[C]"
        session.settings.regularExpression = true
        session.settings.counter.digits = 3
        session.save(as: "  numbered ")
        session.settings = .unchanged
        session.save(as: "Zero")
        session.save(as: " ")
        #expect(session.store.savedNames == ["numbered", "Zero"])
        #expect(
            session.load("numbered") && session.settings.nameMask == "[N]_[C]" && session.settings.counter.digits == 3
        )
        #expect(names(session).first == "IMG_1001_001.jpg")
        #expect(!session.load("unknown"))
        session.deleteSaved("Zero")
        #expect(RenameStore(settings: settings).savedNames == ["numbered"])

        // Reopening keeps the last settings of this run of the program…
        session.settings.nameMask = "last[C]"
        session = open(["IMG_*"])
        #expect(session.settings.nameMask == "last[C]")
        // …a name opens those settings, an unknown name the defaults…
        #expect(open(["IMG_*"], settingsName: "numbered").settings.nameMask == "[N]_[C]")
        #expect(open(["IMG_*"], settingsName: "nothing").settings == .unchanged)
        // …and so does the preference.
        settings.set("numbered", forKey: RenameStore.startupSettingsKey)
        #expect(open(["IMG_*"]).settings.regularExpression)
    }

    /// The histories keep their limit and newest entry first, and title case uses the preference's words.
    @Test
    internal func historiesAndTitleWords() {
        let store = RenameStore(settings: settings)
        store.remember(" a", in: .search)
        store.remember("b", in: .search)
        store.remember(" a", in: .search)
        store.remember("", in: .search)
        #expect(store.history(.search) == [" a", "b"] && store.history(.replacement).isEmpty)
        store.forget("b", in: .search)
        #expect(store.history(.search) == [" a"])
        for index in 0..<30 {
            store.remember("m\(index)", in: .nameMask)
        }
        #expect(store.history(.nameMask).count == RenameStore.historyLimit && store.history(.nameMask).first == "m29")

        settings.set("Mine:img", forKey: RenameStore.lowercaseWordsKey)
        memory.addFile("/titles/the img of img.txt")
        left.show(memory.url("/titles"))
        let session = open()
        session.settings.letterCase = .titleWords
        #expect(names(session) == ["The img Of Img.txt"])
    }
}
