import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The Lister's menus: how their keys are shown, and what each entry does.
@MainActor
@Suite(.serialized)
internal struct CoverageViewerPaneMenuTests {
    private static let text = (1...40).map { "Line \($0) of the text, with words\n" }.joined()

    /// The keys of the entries are shown as the Mac writes them.
    @Test
    internal func shortcutsAreShownAsTheMacWritesThem() {
        #expect(Shortcut(.character("c"), [.control, .option, .shift, .command]).displayText == "⌃⌥⇧⌘C")
        #expect(Shortcut(.function(7)).displayText == "F7")
        #expect(Shortcut(.returnKey, .option).displayText == "⌥↩" && Shortcut(.enter).displayText == "↩")
        #expect(Shortcut(.keypadPlus).displayText == "Num +" && Shortcut(.keypadMinus).displayText == "Num −")
        #expect(Shortcut(.leftArrow).displayText == "←" && Shortcut(.rightArrow).displayText == "→")
        #expect(Shortcut(.upArrow).displayText == "↑" && Shortcut(.downArrow).displayText == "↓")
        #expect(Shortcut(.home).displayText == Shortcut(.home).notation)
    }

    /// The strip fills its menus when they open; a menu the strip does not have is left alone.
    @Test
    internal func theStripFillsItsMenus() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        let buttons = CoverageViewerMenus.stripButtons(of: pane)
        #expect(buttons.count == 4)
        for button in buttons {
            let menu = try #require(button.menu)
            pane.menuNeedsUpdate(menu)
            pane.menuNeedsUpdate(menu)
            #expect(menu.items.count > 3)
        }
        let other = NSMenu()
        pane.menuNeedsUpdate(other)
        #expect(other.items.isEmpty && pane.menuEntries("Help").isEmpty)
        #expect(pane.menuTitles("File").contains("-"))
    }

    /// File: open, save, print, page setup, reload, edit, next, previous and close.
    @Test
    internal func theFileMenu() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let notes = try bench.file("notes.txt", text: Self.text)
        let other = try bench.file("other.txt", text: "Other file\n")
        bench.setup.plugin.open(
            [ViewerItem(source: .file(notes), title: "notes"), ViewerItem(source: .file(other), title: "other")],
            internalOnly: false
        )
        let controller = try #require(bench.setup.plugin.windows.last)
        let pane = controller.pane
        bench.prepare(pane)
        #expect(await bench.textShown(pane))
        // Next and previous step through the session.
        #expect(CoverageViewerMenus.run("Next File", in: "File", of: pane))
        #expect(await bench.wait { pane.item?.url == other && pane.loaded != nil })
        #expect(CoverageViewerMenus.run("Previous", in: "File", of: pane))
        #expect(await bench.wait { pane.item?.url == notes && pane.loaded != nil })
        // Open: a file the panel gives, nothing when it is cancelled.
        #expect(CoverageViewerMenus.run("Open", in: "File", of: pane))
        #expect(pane.item?.url == notes)
        bench.dialogs.fileAnswer = other
        #expect(CoverageViewerMenus.run("Open", in: "File", of: pane))
        #expect(await bench.wait { pane.item?.url == other && pane.loaded != nil })
        // Reload reads it again.
        let generation = pane.loadGeneration
        #expect(CoverageViewerMenus.run("Reload", in: "File", of: pane))
        #expect(await bench.wait { pane.loadGeneration > generation && pane.loaded != nil })
        // Page setup keeps the margins the user confirmed.
        #expect(CoverageViewerMenus.run("Page Setup", in: "File", of: pane))
        #expect(bench.settings.printMargins == nil)
        bench.dialogs.layoutAnswer = true
        #expect(CoverageViewerMenus.run("Page Setup", in: "File", of: pane))
        #expect(bench.settings.printMargins?.count == 4)
        // Print runs an operation with the window.
        #expect(await bench.textShown(pane))
        #expect(CoverageViewerMenus.run("Print", in: "File", of: pane))
        #expect(await bench.wait { bench.dialogs.operations.count == 1 })
        #expect(bench.dialogs.operations.first?.hadWindow == true)
        // Edit goes to the editor with the file.
        var edited: [URL] = []
        bench.setup.commands.register(Command(.edit, "Edit")) { argument in
            if let location = argument.location {
                edited.append(location)
            }
        }
        #expect(CoverageViewerMenus.run("Edit", in: "File", of: pane))
        #expect(edited == [other])
        // Close closes the window.
        #expect(CoverageViewerMenus.run("Close", in: "File", of: pane))
        #expect(await bench.wait { bench.setup.plugin.windows.isEmpty })
    }

    /// Save as: cancelled, onto the file that is shown, into a folder that cannot take it, and
    /// done.
    @Test
    internal func saveAs() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let notes = try bench.file("notes.txt", text: Self.text)
        let pane = try #require(await bench.open(notes))
        #expect(CoverageViewerMenus.run("Save as", in: "File", of: pane))
        #expect(bench.dialogs.proposedNames == ["notes.txt"])
        bench.dialogs.saveAnswer = notes
        #expect(CoverageViewerMenus.run("Save as", in: "File", of: pane))
        #expect(bench.interaction.log.last?.contains("is being shown from the place you chose") == true)
        let locked = bench.folder.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        #expect(chmod(locked.path, 0o500) == 0)
        defer { chmod(locked.path, 0o700) }
        bench.dialogs.saveAnswer = locked.appendingPathComponent("copy.txt")
        #expect(CoverageViewerMenus.run("Save as", in: "File", of: pane))
        #expect(
            await bench.wait { bench.interaction.log.contains { $0.hasPrefix("report") || $0.contains("Save as") } }
        )
        let copy = bench.folder.appendingPathComponent("copy.txt")
        bench.dialogs.saveAnswer = copy
        #expect(CoverageViewerMenus.run("Save as", in: "File", of: pane))
        #expect(await bench.wait { (try? Data(contentsOf: copy)) == Data(Self.text.utf8) })
        // A text that is no file is saved under its title.
        bench.setup.plugin.view(text: "a note", title: "Note")
        let note = try #require(bench.setup.plugin.windows.last?.pane)
        bench.prepare(note)
        #expect(await bench.wait { note.loaded != nil })
        bench.dialogs.saveAnswer = nil
        #expect(CoverageViewerMenus.run("Save as", in: "File", of: note))
        #expect(bench.dialogs.proposedNames.last == "Note")
    }

    /// Options: the modes, the fonts, wrapping, the cursor, the size, the window, configure
    /// and save position.
    @Test
    internal func theOptionsMenuForText() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        #expect(await bench.textShown(pane))
        for mode in ["2 ", "3 ", "6 ", "7 ", "1 "] {
            #expect(CoverageViewerMenus.run(mode, in: "Options", of: pane))
            #expect(await bench.textShown(pane))
        }
        for font in ["ASCII", "Variable", "ANSI"] {
            #expect(CoverageViewerMenus.run(font, in: "Options", of: pane))
        }
        #expect(pane.fontSlot == .ansi && CoverageViewerMenus.item("ANSI", in: "Options", of: pane)?.state == .on)
        let wrap = bench.settings.wrap
        #expect(CoverageViewerMenus.run("Wrap text", in: "Options", of: pane))
        #expect(bench.settings.wrap != wrap)
        #expect(CoverageViewerMenus.run("Show text cursor", in: "Options", of: pane))
        #expect(pane.pager.showsCaret == bench.settings.caret)
        #expect(CoverageViewerMenus.run("Larger", in: "Options", of: pane))
        #expect(CoverageViewerMenus.run("Smaller", in: "Options", of: pane))
        #expect(CoverageViewerMenus.run("Smaller", in: "Options", of: pane))
        #expect(pane.fontSizeChange == -1)
        #expect(CoverageViewerMenus.run("Actual size", in: "Options", of: pane))
        #expect(pane.fontSizeChange == 0)
        #expect(CoverageViewerMenus.run("Full screen", in: "Options", of: pane))
        #expect(CoverageViewerMenus.run("Maximize", in: "Options", of: pane))
        #expect(bench.dialogs.windowChanges == ["full screen", "zoom"])
        bench.settings.setWindowFrame("", quick: false)
        #expect(CoverageViewerMenus.run("Save position", in: "Options", of: pane))
        #expect(bench.settings.windowFrame(quick: false)?.isEmpty == false)
        #expect(CoverageViewerMenus.run("Configure", in: "Options", of: pane))
        #expect(bench.interaction.log.last == "form: Configure Lister")
    }

    /// Options for an image: zoom, fitting, centring and turning.
    @Test
    internal func theOptionsMenuForImages() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let png = try CoverageViewerImages.encoded([CoverageViewerImages.picture(30, 20)], type: "public.png")
        let pane = try #require(await bench.open(try bench.file("picture.png", png)))
        #expect(await bench.wait { pane.imageView != nil })
        let image = try #require(pane.imageView)
        #expect(CoverageViewerMenus.run("Larger", in: "Options", of: pane))
        #expect(abs(image.zoom - 1.25) < 0.001)
        #expect(CoverageViewerMenus.run("Smaller", in: "Options", of: pane))
        #expect(CoverageViewerMenus.run("Actual size", in: "Options", of: pane))
        #expect(image.zoom == 1)
        #expect(CoverageViewerMenus.run("Fit image to window", in: "Options", of: pane))
        #expect(image.fit == .window && bench.settings.imageFit == .window)
        #expect(CoverageViewerMenus.run("Fit only larger", in: "Options", of: pane))
        #expect(image.fit == .largerOnly)
        #expect(CoverageViewerMenus.run("Fit only larger", in: "Options", of: pane))
        #expect(image.fit == .none)
        #expect(CoverageViewerMenus.run("Center images", in: "Options", of: pane))
        #expect(image.centered)
        #expect(CoverageViewerMenus.run("Rotate right", in: "Options", of: pane))
        #expect(CoverageViewerMenus.run("Rotate left", in: "Options", of: pane))
        #expect(pane.percentText == "100.0 %")
    }

    /// Encoding: as configured, Unicode and UTF-8, the code pages, and one entered by number.
    @Test
    internal func theEncodingMenu() async throws {
        let bench = try CoverageViewerPaneBench()
        defer { bench.close() }
        let pane = try #require(await bench.open(try bench.file("notes.txt", text: Self.text)))
        #expect(await bench.textShown(pane))
        #expect(CoverageViewerMenus.run("UTF-16 LE", in: "Encoding", of: pane))
        #expect(pane.mode == .unicode && pane.encoding == .utf16LE)
        #expect(CoverageViewerMenus.item("UTF-16 LE", in: "Encoding", of: pane)?.state == .on)
        #expect(CoverageViewerMenus.run("UTF-8", in: "Encoding", of: pane))
        #expect(pane.mode == .utf8)
        #expect(CoverageViewerMenus.run("Cyrillic Windows", in: "Encoding", of: pane))
        #expect(pane.mode == .text && pane.encoding.codePage == 1_251)
        #expect(CoverageViewerMenus.item("Cyrillic Windows", in: "Encoding", of: pane)?.state == .on)
        #expect(CoverageViewerMenus.run("As configured", in: "Encoding", of: pane))
        #expect(pane.codePage == nil)
        // Other: cancelled, a number, a name with a number kept in the menu, and pages that are not there.
        #expect(CoverageViewerMenus.run("Other", in: "Encoding", of: pane))
        bench.interaction.promptAnswers = [.text("866")]
        #expect(CoverageViewerMenus.run("Other", in: "Encoding", of: pane))
        #expect(pane.codePage?.codePage == 866)
        bench.interaction.promptAnswers = [.text("Latin 2 (28592)")]
        #expect(CoverageViewerMenus.run("Other", in: "Encoding", of: pane))
        #expect(bench.settings.userCodePages == [28_592])
        #expect(CoverageViewerMenus.item("Code page 28592", in: "Encoding", of: pane) != nil)
        bench.interaction.promptAnswers = [.text("Again (28592)")]
        #expect(CoverageViewerMenus.run("Other", in: "Encoding", of: pane))
        #expect(bench.settings.userCodePages == [28_592])
        for answer in ["99999", "Nothing (abc)"] {
            bench.interaction.promptAnswers = [.text(answer)]
            #expect(CoverageViewerMenus.run("Other", in: "Encoding", of: pane))
            #expect(bench.interaction.log.last?.contains("is not available") == true)
        }
        // A file that is not loaded takes no encoding.
        let fresh = ViewerPane(
            kernel: bench.setup.bench.kernel,
            settings: bench.settings,
            temporaryCopies: TemporaryCopies(),
            isEmbedded: false
        )
        fresh.setEncoding(.utf8)
        fresh.setMode(.hex)
        #expect(fresh.mode == .text)
    }
}
