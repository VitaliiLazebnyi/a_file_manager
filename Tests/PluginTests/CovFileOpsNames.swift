import AFMKernel
import Foundation
import Testing

@testable import FileOperationsPlugin

/// New names from a template, target masks and the wording of the dialogs: the forms the other tests do not use.
@Suite
internal struct CovFileOpsNames {
    /// Noon on 2026-10-12, in a calendar of UTC.
    private var context: NameTemplate.Context {
        var made = NameTemplate.Context()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        made.calendar = calendar
        made.now = Date(timeIntervalSince1970: 1_791_806_400)
        made.cursorName = "report.txt"
        return made
    }

    /// The failures say what went wrong.
    @Test
    internal func theFailuresSayWhatWentWrong() {
        #expect(NameTemplate.Failure.emptyClipboard.errorDescription == "The clipboard holds no text for [X].")
        #expect(NameTemplate.Failure.noFreeName("a").errorDescription == "No free name was found for a.")
    }

    /// Empty parts of a list name nothing; a list is no range, and neither is a range that runs backwards.
    @Test
    internal func listsAndBackwardRangesAreNoRanges() throws {
        #expect(try NameTemplate.names(from: "<a| |b", context: context) == ["a", "b"])
        #expect(NameTemplate.rangePreview("<a|b", context: context) == nil)
        #expect(try NameTemplate.names(from: "<5-2>x", context: context) == ["5-2>x"])
    }

    /// Only the first line of the clipboard is taken.
    @Test
    internal func onlyTheFirstLineOfTheClipboardIsTaken() {
        #expect(NameTemplate.clipboardText("first\r\nsecond") == "first")
        #expect(NameTemplate.clipboardText("").isEmpty)
    }

    /// A counter takes its width after a colon and ignores a start and a step; other letters make it no counter.
    @Test
    internal func aCounterTakesItsWidth() throws {
        #expect(try NameTemplate.names(from: "<1-2>n[C10+5:3]", context: context) == ["n001", "n002"])
        #expect(try NameTemplate.names(from: "<1-2>n[C-1a]", context: context) == ["n1", "n2"])
        #expect(try NameTemplate.names(from: "<n[Cx]", context: context) == ["n[Cx]"])
    }

    /// Time switches move the moment; an offset that is no number, or a unit there is not, is no switch.
    @Test
    internal func timeSwitchesMoveTheMoment() throws {
        #expect(try NameTemplate.names(from: "<[T2+1D][D]", context: context) == ["13"])
        #expect(try NameTemplate.names(from: "<[T2+xD]", context: context) == ["[T2+xD]"])
        #expect(try NameTemplate.names(from: "<[T2+1Q]", context: context) == ["[T2+1Q]"])
    }

    /// The hours of the clock: noon is 12, and before and after noon is told long or short.
    @Test
    internal func theHoursOfTheClock() throws {
        #expect(try NameTemplate.names(from: "<[H i i1 v]", context: context) == ["12 pm p 000"])
        var morning = context
        morning.now = context.now.addingTimeInterval(-12 * 3_600)
        #expect(try NameTemplate.names(from: "<[H i i1 y]", context: morning) == ["12 am a 26"])
    }

    /// An empty bracket stays as typed; a range with an end that is not a number, or text after it, is none.
    @Test
    internal func oddBracketsStayAsTyped() throws {
        #expect(try NameTemplate.names(from: "<a[]b", context: context) == ["a[]b"])
        #expect(try NameTemplate.names(from: "<[N2-x]", context: context) == ["[N2-x]"])
        #expect(try NameTemplate.names(from: "<[N2-3x]", context: context) == ["[N2-3x]"])
        #expect(try NameTemplate.names(from: "<[N2x]", context: context) == ["[N2x]"])
    }

    /// A target mask gives a name without an extension where the source has none, or the mask asks for none.
    @Test
    internal func aTargetMaskGivesNamesWithoutExtensions() {
        #expect(TargetMask.apply("*.txt", to: "README") == "README.txt")
        #expect(TargetMask.apply("*.", to: "a.txt") == "a")
        let folder = URL(fileURLWithPath: "/x")
        let taken: Set<String> = ["/x/a.txt", "/x/a (2).txt", "/x/b", "/x/b (2)"]
        #expect(
            UniqueName.available(for: folder.appending(path: "a.txt")) { taken.contains($0.path) }.lastPathComponent
                == "a (3).txt"
        )
        #expect(
            UniqueName.available(for: folder.appending(path: "b")) { taken.contains($0.path) }.lastPathComponent
                == "b (3)"
        )
    }

    /// The questions name one item, or count them; a protected item to be moved is asked about as a move.
    @Test
    internal func theQuestionsNameOrCount() {
        let file = FileItem(url: URL(fileURLWithPath: "/x/a.txt"), name: "a.txt", stat: .init(size: 1))
        #expect(
            OperationText.deleteQuestion(count: 2, single: file, toTrash: false)
                == "Do you really want to delete the 2 selected files/directories?"
        )
        let question = ProtectionQuestion(reason: .locked, purpose: .move, item: file)
        let text = OperationText.protection(question, path: "/x/a.txt")
        #expect(text.message == "Move: /x/a.txt is LOCKED!" && text.action == "Move")
    }
}
