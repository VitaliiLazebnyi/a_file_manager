import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import TestSupport
import Testing

@testable import ViewerPlugin

/// Finding, selecting, copying and going to a place in a Lister window.
@MainActor
@Suite(.serialized)
internal struct ViewerPluginSearchTests: ViewerPluginFixture {
    /// The viewer and the program around it, made for this test.
    internal let setup: ViewerPluginSetup

    /// Makes the viewer over its files for this test.
    internal init() throws {
        setup = try ViewerPluginSetup()
    }

    // MARK: Search, selection, clipboard

    /// Find searches the whole file, repeats in both directions and as a regular expression, and reports what it could
    /// not find.
    @Test
    internal func findSearchesTheWholeFileAndRepeatsInBothDirections() async throws {
        let controller = try await openLister(on: "long.txt")
        let pane = controller.pane
        #expect(await rowsShown(controller))
        let source = try #require(memory.contents("/A/long.txt"))
        // The byte offset of the first (or last) place the text is in the file.
        func offset(of text: String, last: Bool) throws -> Int64 {
            let range = try #require(source.range(of: text, options: last ? .backwards : []))
            return Int64(source.utf8.distance(from: source.startIndex, to: range.lowerBound))
        }
        let gold = try offset(of: "GOLD", last: false)
        let secondGold =
            try offset(of: "Line 2000 ", last: false) + Int64("Line 2000 of the long text, needle ".utf8.count)
        let lastGold = try offset(of: "needle GOLD", last: true)
        interaction.formAnswers = [.values(["text": .text("gold"), "case": .flag(false)])]
        #expect(pane.handleKey(try functionKey(7, [])))
        #expect(await wait { pane.pager.selection != nil && pane.activity == nil })
        #expect(pane.pager.selection == gold..<gold + 4)
        #expect(await wait { pane.statusText.contains("Line 1,000") && pane.statusText.contains("4 bytes selected") })
        // F3 finds the next one, Shift+F3 the one before, Ctrl+F3 turns around.
        pane.handleKey(try functionKey(3, []))
        #expect(await wait { pane.pager.selection?.lowerBound == secondGold })
        pane.handleKey(try functionKey(3, .shift))
        #expect(await wait { pane.pager.selection?.lowerBound == gold })
        pane.handleKey(try functionKey(5, .control))
        #expect(await wait { pane.pager.selection?.lowerBound != gold && pane.activity == nil })
        #expect(await wait { pane.statusText.contains("Line 2,000") })
        // Backwards from the end, as a regular expression.
        pane.pager.perform(.fileEnd)
        #expect(await wait { pane.pager.selection == nil && pane.statusText.contains("Line 5,000") })
        interaction.formAnswers = [
            .values([
                "text": .text("needle G.LD$"), "regex": .flag(true), "backwards": .flag(true), "case": .flag(true)
            ])
        ]
        pane.find()
        #expect(await wait { pane.pager.selection?.lowerBound == lastGold })
        #expect(await wait { pane.statusText.contains("Line 5,000") })
        #expect(pane.settings.searchHistory == ["needle G.LD$", "gold"] && pane.settings.searchOptions.regex)
        // What is not there is said so, and a bad pattern too.
        interaction.formAnswers = [
            .values(["text": .text("no such text"), "regex": .flag(false), "backwards": .flag(false)])
        ]
        pane.find()
        #expect(await wait { interaction.log.contains("inform: \"no such text\" was not found.") })
        interaction.formAnswers = [.values(["text": .text("zz"), "hex": .flag(true)])]
        pane.find()
        #expect(interaction.log.contains("inform: Find"))
    }

    /// The selection, made with the keys or the cursor, is copied as text or as hex.
    @Test
    internal func theSelectionIsCopiedAsTextOrAsHex() async throws {
        let controller = try await openLister(on: "short.txt")
        let pane = controller.pane
        #expect(await rowsShown(controller))
        #expect(pane.menuEntries("Edit").compactMap(\.self).first { $0.title == "Copy as text" }?.isEnabled == false)
        #expect(pane.handleKey(try key("a", .control)))
        #expect(pane.pager.selection == 0..<31)
        #expect(pane.handleKey(try key("c", .control)))
        #expect(await wait { pasteboard.string(forType: .string) == "Grüße\tfrom a file\nsecond line" })
        // The text cursor: Shift with the cursor keys selects.
        pane.pager.perform(.fileStart)
        pane.pager.perform(.right, extending: true)
        pane.pager.perform(.right, extending: true)
        pane.pager.perform(.right, extending: true)
        #expect(pane.pager.selection == 0..<4)
        #expect(pane.handleKey(try key("c", [.control, .shift])))
        #expect(await wait { pasteboard.string(forType: .string) == "47 72 C3 BC" })
        pane.pager.perform(.rowDown)
        #expect(await wait { pane.pager.selection == nil && pane.statusText.contains("Line 2") })
        pane.pager.perform(.rowEnd, extending: true)
        pane.copySelection(asHex: false)
        #expect(await wait { pasteboard.string(forType: .string) == "ond line" })
        pane.pager.perform(.wordLeft, extending: false)
        pane.pager.perform(.rowStart, extending: true)
        #expect(pane.pager.selection == 20..<27)
    }

    /// A place is reached by line, offset or percent, and the pane draws and prints what it shows.
    @Test
    internal func positionsAreReachedByPercentOffsetAndLine() async throws {
        let controller = try await openLister(on: "long.txt")
        let pane = controller.pane
        #expect(await rowsShown(controller))
        interaction.promptAnswers = [.text("4000")]
        pane.goToLine()
        #expect(await wait { pane.statusText.contains("Line 4,000") })
        interaction.promptAnswers = [.text("0x0")]
        pane.goToOffset()
        #expect(await wait { pane.statusText.contains("Line 1 ") })
        interaction.promptAnswers = [.text("50,5")]
        pane.goToPercent()
        #expect(await wait { pane.pager.position.map { (2_400...2_700).contains($0.line) } == true })
        #expect(await wait { pane.percentText == "51 %" || pane.percentText == "50 %" || pane.percentText == "52 %" })
        interaction.promptAnswers = [.text("99999")]
        pane.goToLine()
        #expect(await wait { interaction.log.contains("inform: There is no line 99999.") })
        #expect(
            ViewerPane.number(in: "20,7 %") == 20.7 && ViewerPane.offset(in: "$FF") == 255
                && ViewerPane.offset(in: "1,024") == 1_024
        )
        // The view draws what it holds.
        let image = try #require(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
        pane.cacheDisplay(in: pane.bounds, to: image)
        #expect(image.pixelsWide > 0)
        #expect(
            ViewerPane.printableText(
                of: try #require(pane.pager.document),
                in: 0..<60,
                maxRows: ViewerPane.printPageLimit * 60,
                cancellation: CancellationFlag()
            )
            .text
                == "Line 1 of the long text, needle\nLine 2 of the long text, needle\n"
        )
    }
}
