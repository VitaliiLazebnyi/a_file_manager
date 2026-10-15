import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import CompareContentPlugin

/// The compare window's controls: the options, the files typed or chosen, the font, and what it asks before it
/// gives edits up.
@MainActor
@Suite
internal struct CoverageCompareWindow {
    /// Twenty lines, and the same with line 3 changed, line 10 gone and a line after 15 added.
    internal static let left = (0..<20).map { "line \($0)" }.joined(separator: "\n") + "\n"
    /// See `left`.
    internal static let right =
        (0..<20)
        .compactMap { index -> String? in
            switch index {
            case 3:
                return "changed 3"

            case 10:
                return nil

            case 15:
                return "line 15\nnew line"

            default:
                return "line \(index)"
            }
        }
        .joined(separator: "\n") + "\n"

    /// The options follow their boxes, are remembered, and Binary reads the files again.
    @Test
    internal func theOptionsFollowTheirBoxes() throws {
        let stage = CoverageCompareStage(left: Self.left, right: Self.right)
        defer { stage.close() }
        #expect(stage.session.blocks.count == 3)
        // Upper and lower case count: still three differences.
        stage.toggle("Ignore case")
        #expect(!stage.session.options.ignoreCase && stage.session.blocks.count == 3)
        stage.toggle("Ignore repeated spaces")
        stage.toggle("Ignore line-end differences")
        #expect(!stage.session.options.ignoreRepeatedSpaces && !stage.session.options.ignoreLineEndings)
        stage.toggle("Binary")
        #expect(stage.session.forceBinary && stage.session.isBinary)
        let popup = try #require(stage.views(NSPopUpButton.self).first)
        popup.selectItem(at: 3)
        _ = popup.target?.perform(popup.action, with: popup)
        #expect(stage.session.bytesPerLine == 32)
        stage.toggle("Binary")
        #expect(!stage.session.isBinary)
        stage.toggle("Above each other")
        #expect(stage.bench.kernel.settings.flag("compareContent.vertical", default: false))
        stage.toggle("Edit mode")
        #expect(stage.session.isEditing)
    }

    /// Unsaved edits are asked about before the files are read again: saved, given up, or kept.
    @Test
    internal func unsavedEditsAreAskedAboutBeforeTheFilesAreReadAgain() {
        let stage = CoverageCompareStage(left: Self.left, right: Self.right)
        defer { stage.close() }
        let interaction = stage.bench.interaction
        stage.toggle("Edit mode")
        stage.session.copy(rows: 3..<4, to: .right)
        #expect(stage.session.hasUnsavedChanges)
        // Cancel: nothing happens.
        interaction.choiceAnswers = [2]
        stage.click("Compare")
        #expect(stage.session.hasUnsavedChanges)
        // Don't Save: the files are read again as they are.
        interaction.choiceAnswers = [1]
        stage.click("Compare")
        #expect(!stage.session.hasUnsavedChanges && stage.memory.contents("/B/right.txt") == Self.right)
        // Save: written first, then read again.
        stage.session.copy(rows: 3..<4, to: .right)
        interaction.choiceAnswers = [0]
        stage.toggle("Binary")
        #expect(stage.session.isBinary && stage.memory.contents("/B/right.txt")?.contains("changed 3") == false)
    }

    /// Typed paths are compared, an empty one leaves its side empty, and a chosen file is compared at once.
    @Test
    internal func typedAndChosenFilesAreCompared() throws {
        let stage = CoverageCompareStage(left: Self.left, right: Self.right)
        defer { stage.close() }
        stage.memory.addFile("/A/other.txt", "other\n")
        let fields = stage.pathFields
        try #require(fields.count == 2)
        fields[0].stringValue = "mem:///A/other.txt"
        stage.click("Compare")
        #expect(stage.session.leftURL?.path == "/A/other.txt" && stage.session.blocks.count == 1)
        fields[1].stringValue = "  "
        stage.click("Compare")
        #expect(stage.session.rightURL == nil && stage.session.phase == .empty)
        // The file panel: cancelled, then a file chosen for the right side.
        let choosers = stage.views(NSButton.self).filter { $0.title == ">>" }
        _ = choosers[1].target?.perform(choosers[1].action, with: choosers[1])
        #expect(stage.session.rightURL == nil)
        stage.recorder.chosen = [URL(fileURLWithPath: "/B/right.txt")]
        _ = choosers[1].target?.perform(choosers[1].action, with: choosers[1])
        #expect(fields[1].stringValue == "/B/right.txt")
        // With one side empty the choice only fills the field.
        fields[1].stringValue = ""
        stage.recorder.chosen = [URL(fileURLWithPath: "/A/left.txt")]
        _ = choosers[0].target?.perform(choosers[0].action, with: choosers[0])
        #expect(fields[0].stringValue == "/A/left.txt" && stage.session.leftURL?.path == "/A/other.txt")
    }

    /// The font is chosen in the font panel and remembered.
    @Test
    internal func theFontIsChosenAndRemembered() throws {
        let stage = CoverageCompareStage(left: Self.left, right: Self.right)
        defer { stage.close() }
        let controller = try #require(stage.controller)
        stage.click("Font…")
        #expect(stage.recorder.fontPanels == 1 && NSFontManager.shared.target === controller)
        controller.changeFont(nil)
        // "Bigger" in the font panel: the panel sends the change to the window.
        let bigger = NSMenuItem()
        bigger.tag = Int(NSFontAction.sizeUpFontAction.rawValue)
        NSFontManager.shared.modifyFont(bigger)
        #expect(stage.bench.kernel.settings.text("compareContent.fontSize", default: "") == "13.0")
        stage.close()
        // Closed: the font panel no longer talks to it.
        #expect(NSFontManager.shared.target == nil)
    }

    /// A remembered font size that is not a number gives the usual size; the options shown are the session's.
    @Test
    internal func theWindowStartsFromTheSessionAndTheSettings() {
        let settings = MemorySettings()
        settings.set("large", forKey: "compareContent.fontSize")
        settings.set(false, forKey: "compareContent.ignoreCase")
        settings.set(false, forKey: "compareContent.ignoreRepeatedSpaces")
        settings.set(false, forKey: "compareContent.ignoreLineEndings")
        settings.set(true, forKey: "compareContent.vertical")
        let stage = CoverageCompareStage(left: Self.left, right: Self.right, settings: settings)
        defer { stage.close() }
        #expect(stage.button("Ignore case")?.state == .off)
        #expect(stage.button("Above each other")?.state == .on)
        #expect(stage.session.blocks.count == 3)
    }

    /// A window for one file only starts from that file's folder, and a width of bytes the popup does not have
    /// selects the usual one.
    @Test
    internal func aWindowForOneFileAndAnOddWidth() throws {
        let stage = CoverageCompareStage(left: Self.left, right: Self.right)
        defer { stage.close() }
        let controller = try #require(stage.controller)
        stage.session.leftURL = nil
        stage.session.bytesPerLine = 12
        controller.show()
        #expect(stage.views(NSPopUpButton.self).first?.indexOfSelectedItem == 1)
        #expect(stage.pathFields.first?.stringValue.isEmpty == true)
        // Nothing to save: the window closes when asked.
        stage.askToClose()
        #expect(stage.wasClosed)
    }

    /// A window is never made from an archive.
    @Test
    internal func aWindowIsNeverMadeFromAnArchive() async {
        await #expect(processExitsWith: .exitCode(1)) {
            CoverageCoreTrap.exitOnTrap()
            await MainActor.run { _ = CompareWindowController(coder: NSCoder()) }
        }
    }

    /// Closing with edits that are not saved asks first.
    @Test
    internal func closingWithUnsavedEditsAsksFirst() {
        let stage = CoverageCompareStage(left: Self.left, right: Self.right)
        defer { stage.close() }
        #expect(stage.recorder.presented == 1)
        stage.toggle("Edit mode")
        stage.session.copy(rows: 3..<4, to: .right)
        stage.bench.interaction.choiceAnswers = [2]
        stage.askToClose()
        #expect(!stage.wasClosed)
        stage.bench.interaction.choiceAnswers = [1]
        stage.askToClose()
        #expect(stage.wasClosed)
    }
}
