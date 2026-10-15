import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The colours of names through the real program (spec 03 › Colours by file type) and the
/// options page of the lists.
@MainActor
@Suite(.serialized)
internal struct PanelColoursTests {
    private let program: PanelProgram

    /// The program's folders, with a hidden file in `A`.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
        try program.box.file("A/.secret")
    }

    /// Names are coloured by mark, then by file type, hidden ones dimmed; the list is edited as
    /// text, the switch turns the colours off without losing the list, and the options page
    /// changes both panels.
    @Test
    internal func namesAreColouredByMarkAndFileType() async {
        let app = await program.start(
            plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard),
            fileSystems: []
        )
        defer { app.stop() }
        app.commands.perform(.showHidden, .nothing)
        await program.settle(app)
        let model = app.left.model
        func color(_ name: String, selected: Bool) -> NSColor {
            app.left.nameColor(for: model.items.first { $0.name == name }, selected: selected)
        }
        #expect(
            color("one.txt", selected: false) == .labelColor
                && color(".secret", selected: false) == .secondaryLabelColor
        )
        #expect(
            color("one.txt", selected: true) == .systemRed
                && app.left.nameColor(for: nil, selected: false) == .labelColor
        )
        #expect(!app.commands.isChecked("cm_SwitchColorsByFileType"))
        // The list is edited as text; an entry that cannot be read is shown again; cancelling changes nothing.
        program.interaction.formAnswers = [
            .values(["rules": .text("*.txt = nocolour"), "enabled": .flag(true)]),
            .values(["rules": .text("one.* = blue\n*.txt .* = #00FF00\n-docs = red"), "enabled": .flag(true)])
        ]
        app.commands.perform("afm_DefineColorsByFileType", .nothing)
        #expect(program.interaction.log.filter { $0.hasPrefix("inform") } == ["inform: This entry cannot be read:"])
        #expect(app.commands.isChecked("cm_SwitchColorsByFileType"))
        let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        #expect(color("one.txt", selected: false) == .systemBlue && color("two.txt", selected: false) == green)
        #expect(color(".secret", selected: false) == green && color("docs", selected: false) == .labelColor)
        // The mark colour wins; the switch turns the colours off without losing the list.
        #expect(color("one.txt", selected: true) == .systemRed)
        app.commands.perform("cm_SwitchColorsByFileType", .nothing)
        #expect(color("one.txt", selected: false) == .labelColor)
        #expect(program.settings.text(PanelSettings.colorRulesKey, default: "").hasPrefix("one.* = blue;;"))
        program.interaction.formAnswers = []
        app.commands.perform("afm_DefineColorsByFileType", .nothing)
        #expect(!app.commands.isChecked("cm_SwitchColorsByFileType"))
        // The options page of the lists is there, next to the plugin's.
        let titles = app.kernel.preferences.pages.map(\.title)
        #expect(titles.contains("File Panels") && titles.contains("Display"))
        program.settings.set(4, forKey: PanelSettings.thumbnailSizeKey)
        app.kernel.preferences.pages.first { $0.title == "File Panels" }?.onChange()
        #expect(app.left.settings.thumbnailSide == 256 && app.right.settings.thumbnailSide == 256)
    }

    /// The commands of the panels hold the panels weakly, so the kernel that keeps them does
    /// not keep the panels alive; once the panels are gone, the commands do nothing.
    @Test
    internal func theCommandsOfThePanelsDoNotKeepThePanelsAlive() async {
        let kernel = Kernel(productName: "Test", settings: program.settings, interaction: program.interaction)
        kernel.fileSystems.register(program.memory)
        var coordinator: PanelCoordinator? = PanelCoordinator(kernel: kernel, home: program.box.url("home"))
        weak let gone = coordinator
        if let coordinator {
            PanelShellCommands.register(in: kernel, panels: coordinator)
        }
        coordinator = nil
        #expect(await PanelWait.until { gone == nil })
        kernel.commands.perform(.quickFilter, .nothing)
        kernel.commands.perform(PanelShellCommands.cursorLeft, .nothing)
        kernel.commands.perform(PanelShellCommands.cursorRight, .nothing)
        kernel.commands.perform(PanelShellCommands.switchColorsByFileType, .nothing)
        #expect(program.settings.flag(PanelSettings.colorsByTypeKey, default: false))
        kernel.preferences.pages.first { $0.title == "File Panels" }?.onChange()
    }
}
