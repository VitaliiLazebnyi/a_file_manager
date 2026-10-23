import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// The modes of a Lister window: chosen at startup, switched with their keys, and set in the
/// configuration.
@MainActor
@Suite(.serialized)
internal struct ViewerPluginModeTests: ViewerPluginFixture {
    /// The viewer and the program around it, made for this test.
    internal let setup: ViewerPluginSetup

    /// Makes the viewer over its files for this test.
    internal init() throws {
        setup = try ViewerPluginSetup()
    }

    /// The mode is chosen from the file at startup and switched with its key; the options are remembered.
    @Test
    internal func modesAreChosenAtStartupAndSwitchedWithTheirKeys() async throws {
        let controller = try await openLister(on: "short.txt")
        let pane = controller.pane
        #expect(await rowsShown(controller))
        #expect(pane.mode == .utf8 && pane.encoding == .utf8)
        pane.handleKey(try key("3", []))
        #expect(pane.mode == .hex && pane.pager.document?.layout == .hex)
        #expect(
            visibleText(pane, rows: 1) == [
                "00000000: 47 72 C3 BC C3 9F 65 09|66 72 6F 6D 20 61 20 66 | GrÃ¼ÃŸe.from a f"
            ]
        )
        pane.handleKey(try key("2", []))
        #expect(pane.mode == .binary && pane.pager.document?.layout == .binary(width: 75))
        pane.handleKey(try key("1", []))
        #expect(pane.mode == .text && pane.encoding == .ansi)
        #expect(await rowsShown(controller))
        // Seven characters now, so the tab is one column wide.
        #expect(visibleText(pane, rows: 1) == [ViewerEncoding.ansi.string(from: Data("Grüße".utf8)) + " from a file"])
        // S shows the same bytes in the DOS character set; the Encoding menu overrides the font.
        pane.handleKey(try key("s", []))
        #expect(pane.fontSlot == .ascii && pane.encoding == .dos)
        pane.setEncoding(ViewerEncoding.codePage(1_251))
        #expect(pane.mode == .text && pane.encoding.codePage == 1_251)
        pane.setEncoding(.utf16BE)
        #expect(pane.mode == .unicode && pane.encoding == .utf16BE)
        pane.handleKey(try key("7", []))
        #expect(pane.mode == .utf8 && pane.encoding == .utf8)
        // W turns wrapping off and on; the option is remembered.
        #expect(pane.settings.wrap)
        pane.handleKey(try key("w", []))
        #expect(
            !pane.settings.wrap && pane.pager.document == nil
                || pane.layout == .text(TextLayoutOptions(columns: 1_024, wordWrap: false, tabWidth: 8))
        )
        pane.handleKey(try key("w", []))
        #expect(pane.settings.wrap && ListerSettings(bench.kernel.settings).wrap)
        pane.handleKey(try functionKey(6, []))
        #expect(!pane.settings.caret && !pane.pager.showsCaret)
        // Q closes the window.
        #expect(pane.handleKey(try key("q", [])) && plugin.windows.isEmpty)
    }

    /// Binaries, UTF-16 texts, HTML pages and images open in their modes, and without plugins as bytes.
    @Test
    internal func binaryUnicodeHtmlAndImagesOpenInTheirModes() async throws {
        let binary = try await openLister(on: "tool.bin")
        #expect(binary.pane.mode == .binary && binary.pane.statusText.contains("Binary"))
        let wide = try await openLister(on: "wide.txt")
        #expect(wide.pane.mode == .unicode && wide.pane.encoding == .utf16LE)
        #expect(await rowsShown(wide))
        #expect(visibleText(wide.pane, rows: 3) == ["Wide text", "zwei"])
        let html = try await openLister(on: "page.html")
        #expect(html.pane.mode == .html)
        #expect(await wait { !html.pane.htmlLinks.isEmpty })
        #expect(await rowsShown(html))
        #expect(
            visibleText(html.pane, rows: 3) == ["Title", "See this {https://example.com}."]
                && html.pane.htmlLinks == ["https://example.com"]
        )
        // 1 shows the source.
        html.pane.handleKey(try key("1", []))
        #expect(html.pane.mode == .text && html.pane.htmlLinks.isEmpty)
        let image = try await openLister(on: "broken.png")
        #expect(image.pane.mode == .media)
        #expect(await wait { image.pane.statusText.hasPrefix("Image/Multimedia") })
        // Without plugins and multimedia the same file is shown as what it is: bytes.
        bench.left.moveCursor(toName: "broken.png")
        commands.perform(.viewInternalSingle)
        let plain = try #require(plugin.windows.last)
        #expect(await wait { plain.pane.loaded != nil })
        #expect(plain.pane.internalOnly && plain.pane.mode == .binary)
        #expect(
            plain.pane.menuEntries("Options").compactMap(\.self).first { $0.title.hasPrefix("8 ") }?.isEnabled == false
        )
    }

    /// The configuration decides the startup mode and reaches the windows that are open.
    @Test
    internal func theConfigurationDecidesTheStartupMode() async throws {
        interaction.formAnswers = [
            .values([
                "viewer.startupMode": .index(3), "viewer.htmlAsText": .flag(false), "viewer.binaryWidth": .text("40")
            ])
        ]
        #expect(commands.perform(.configureLister))
        #expect(interaction.forms.last?.count == bench.kernel.preferences.pages[0].preferences.count)
        let hex = try await openLister(on: "short.txt")
        #expect(hex.pane.mode == .hex)
        let html = try await openLister(on: "page.html")
        #expect(html.pane.mode == .hex)
        html.pane.handleKey(try key("2", []))
        #expect(html.pane.layout == .binary(width: 40))
        // Changing the configuration reaches the windows that are open.
        interaction.formAnswers = [.values(["viewer.binaryWidth": .text("16")])]
        html.pane.onConfigure()
        #expect(html.pane.layout == .binary(width: 16))
        #expect(await wait { html.pane.pager.document?.layout == .binary(width: 16) })
        interaction.formAnswers = [.cancel]
        commands.perform(.configureLister)
        #expect(ListerSettings(bench.kernel.settings).binaryWidth == 16)
    }
}
