import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import SelectionPlugin

/// The pure parts of the Mark menu beyond the other suites: selection files that do not read,
/// comparisons that fold case or are cancelled, and the corners of masks and types.
@Suite
internal struct CoverageSelectionRules {
    /// An entry of a list in a folder of memory.
    private func item(_ name: String, folder: Bool = false, size: Int64 = 1) -> FileItem {
        FileItem(
            url: URL(string: "mem:/A/" + name) ?? URL(fileURLWithPath: "/"),
            name: name,
            kind: FileItem.Kind(isDirectory: folder),
            stat: FileItem.Stat(size: size)
        )
    }

    /// A character outside Windows-1252 that comes twice is looked up once and written the
    /// same both times.
    @Test
    internal func repeatedCharactersAreWrittenTheSame() {
        #expect(SelectionFile.windows1252("ééą") == Data([0xE9, 0xE9, 0x61]))
        #expect(SelectionFile.encode([item("é")], as: .unicode) == Data([0xFF, 0xFE, 0xE9, 0x00]))
    }

    /// Bytes that are not the text their mark says read as no names at all.
    @Test
    internal func bytesThatAreNoTextReadAsNothing() {
        for bytes: [UInt8] in [[0xFF, 0xFE, 0x00, 0xD8], [0xFE, 0xFF, 0xD8, 0x00], [0xEF, 0xBB, 0xBF, 0xFF], [0x81]] {
            #expect(SelectionFile.text(from: Data(bytes)).isEmpty, "\(bytes)")
        }
    }

    /// On a volume that does not tell the cases apart, names that differ only in case pair up.
    @Test
    internal func namesPairWithoutRegardToCaseWhereTheVolumeSaysSo() {
        let left = [item("Photo.JPG"), item("Only.txt")]
        let right = [item("photo.jpg")]
        let folded = DirectoryComparison.compare(left: left, right: right, foldingCase: true)
        #expect(folded.left == ["Only.txt"] && folded.right.isEmpty && folded.same == ["Photo.JPG", "photo.jpg"])
        let apart = DirectoryComparison.compare(left: left, right: right)
        #expect(apart.left == ["Photo.JPG", "Only.txt"] && apart.right == ["photo.jpg"])
    }

    /// A comparison cancelled in its second or third pass returns what it had.
    @Test
    internal func aComparisonCancelledLaterReturnsWhatItHad() {
        let left = [item("a.txt"), item("b.txt")]
        let right = [item("a.txt", size: 2)]
        for passes in [1, 2] {
            var asked = 0
            let marks = DirectoryComparison.compareIndices(left: left, right: right, mode: .newerOrDifferent) {
                asked += 1
                return asked > passes
            }
            #expect(marks.left.isEmpty && marks.right.isEmpty && asked == passes + 1, "\(passes)")
        }
    }

    /// A mask of a lone separator names nothing and leaves the others; a folder mask refuses a
    /// file even where the name is not plain ASCII.
    @Test
    internal func loneSeparatorsAndFolderMasksOfOtherNames() {
        let mask = SelectionMask("\\ *.txt")
        #expect(mask.matches("a.txt") && !mask.matches("a.md"))
        let folders = SelectionMask("*/")
        #expect(!folders.matches("é", isFolder: false) && folders.matches("é", isFolder: true))
    }

    /// A name that is not one piece of UTF-8 (one handed over by Foundation) is still matched.
    @Test
    internal func aBridgedNameIsMatched() {
        // Core Foundation keeps it in UTF-16: the string reaches Swift without UTF-8 of its own.
        let characters = Array("Résumé.TXT".utf16)
        let bridged = CFStringCreateWithCharacters(nil, characters, characters.count) as String
        #expect(SelectionMask("*.txt").matches(bridged) && !SelectionMask("*.md").matches(bridged))
    }

    /// `A>` without a related mask pairs nothing; a file without its partner keeps only itself.
    @Test
    internal func relatedMasksWithoutPartners() {
        #expect(!SelectionMask("*.jpg>").pairsRelatedFiles && !SelectionMask("*.jpg> ").pairsRelatedFiles)
        let entries = [MaskEntry(name: "a.jpg"), MaskEntry(name: "b.txt")]
        #expect(SelectionMask("*.jpg>*.cr2").selected(entries) == [true, false])
    }

    /// A rename mask that ends in a dot drops the extension, as in Total Commander: `*.jpg>*.`
    /// pairs a picture with the file of its name alone.
    @Test
    internal func aMaskEndingInADotDropsTheExtension() {
        #expect(Wildcard.rename("report.txt", with: "*.") == "report")
        #expect(Wildcard.rename("report.txt", with: "?.") == "r" && Wildcard.rename("report", with: "*.*") == "report")
        let entries = [MaskEntry(name: "IMG.jpg"), MaskEntry(name: "IMG"), MaskEntry(name: "other")]
        #expect(SelectionMask("*.jpg>*.").selected(entries) == [true, true, false])
    }

    /// A regular expression that ran out of time too often, or a cancelled run, matches
    /// nothing; an empty name is asked as it is.
    @Test
    internal func regularExpressionsGiveUpAndAskEmptyNames() throws {
        let regex = try NSRegularExpression(pattern: "^$")
        let trip = SelectionRegexTrip()
        #expect(SelectionRegex.matches(regex, "", trip: trip) { false })
        #expect(!SelectionRegex.matches(regex, "", trip: trip) { true })
        for _ in 0..<3 { trip.recordTimeout() }
        #expect(trip.isTripped && !SelectionRegex.matches(regex, "", trip: trip) { false })
    }

    /// Sizes: an empty text is none, a size larger than any file is the largest there is.
    @Test
    internal func sizeTexts() {
        #expect(SelectionType.size(from: "  ") == nil && SelectionType.size(from: "1e30") == Int64.max)
    }

    /// An entry of a list gathered from elsewhere, named by its path, is matched by its own name.
    @Test
    internal func anEntryNamedByItsPathIsMatchedByItsName() {
        let gathered = FileItem(
            url: URL(string: "mem:/A/sub/a.txt") ?? URL(fileURLWithPath: "/"),
            name: "sub/a.txt",
            kind: FileItem.Kind(isDirectory: false),
            stat: FileItem.Stat()
        )
        let base = URL(string: "mem:/A") ?? URL(fileURLWithPath: "/")
        #expect(SelectionRule(mask: "a.*").names(among: [gathered], base: base) == ["sub/a.txt"])
        #expect(SelectionRule(mask: "sub*").names(among: [gathered], base: base).isEmpty)
    }
}
