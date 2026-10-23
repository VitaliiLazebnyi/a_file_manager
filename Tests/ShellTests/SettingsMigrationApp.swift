import AFMKernel
import AppKit
import Foundation
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// The program started on settings written by earlier versions, with the real kernel, the
/// core plugins and the shell: the panels come back with their tabs, views and colours, and
/// what the program saves has the shape of what it read.
@MainActor
@Suite(.serialized)
internal struct SettingsMigrationApp {
    /// What earlier versions wrote, one fixture per format.
    ///
    /// The tabs show folders every Mac has, so that the panels can list them.
    internal enum Fixture {
        /// The left panel's tabs as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `left.tabs`: a locked tab named "Tools" on `/usr` sorted by extension, and `/System`
        /// with hidden files, names in reverse order, which is the active one.
        internal static let leftTabs = #"""
            {"tabs":[{"location":"file:\/\/\/usr\/","sortKey":1,"descending":false,"showHidden":false,\#
            "title":"Tools","locked":true},\#
            {"location":"file:\/\/\/System\/","sortKey":0,"descending":true,"showHidden":true}],"active":1}
            """#

        /// The right panel's tabs as the versions before git wrote them: no title, no lock.
        internal static let rightTabs = #"""
            {"tabs":[{"location":"file:\/\/\/usr\/","sortKey":0,"descending":false,"showHidden":false}],"active":0}
            """#

        /// The left panel's view as commit 16d647d (2026-10-14) wrote it.
        ///
        /// `left.view`: Brief, with two plugin columns the core plugins do not offer.
        internal static let leftView = #"{"mode":1,"extraColumns":["upper","length"],"columnWidths":{}}"#
    }

    private let interaction = ScriptedInteraction()
    /// A pasteboard of the test's own, given back when the suite goes.
    private let scratch = ScratchPasteboard()
    /// Where the program's home folder is.
    private let box: Sandbox

    /// Makes a home folder for the program.
    internal init() throws {
        box = try Sandbox()
    }

    /// Settings with the panels' fixtures.
    private static func panelSettings() -> MemorySettings {
        SettingsMigrationShell.settings([
            "left.tabs": Fixture.leftTabs, "right.tabs": Fixture.rightTabs, "left.view": Fixture.leftView
        ])
    }

    /// Ends the shell and the kernel.
    private static func stop(_ shell: Shell, _ kernel: Kernel) {
        shell.shutDown()
        kernel.shutdown()
    }

    /// Starts the program on the settings and waits until both panels are listed.
    private func start(on settings: any SettingsStore) async throws -> (shell: Shell, kernel: Kernel) {
        _ = NSApplication.shared
        let kernel = Kernel(productName: StandardPlugins.productName, settings: settings, interaction: interaction)
        kernel.load(CorePlugins.make(pasteboard: scratch.pasteboard))
        let shell = Shell(kernel: kernel, home: try box.folder("home"))
        let deadline = Date().addingTimeInterval(10)
        while shell.panelCoordinator.isLoading, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return (shell, kernel)
    }

    /// The panels come back with their tabs and views.
    @Test
    internal func thePanelsComeBack() async throws {
        let (shell, kernel) = try await start(on: Self.panelSettings())
        defer { Self.stop(shell, kernel) }
        let (left, right) = (shell.panelCoordinator.leftPanel, shell.panelCoordinator.rightPanel)
        let tabs = left.tabs
        #expect(tabs.count == 2 && tabs.activeIndex == 1 && tabs.title(at: 0) == "*Tools")
        #expect(left.model.directory.path == "/System" && left.model.showHidden)
        #expect(tabs.tabs[0].isLocked && tabs.tabs[0].sort.key == .ext && tabs.tabs[1].sort.descending)
        #expect(left.viewMode == .brief && left.extraColumns == ["upper", "length"])
        #expect(right.tabs.count == 1 && right.model.directory.path == "/usr" && !right.tabs.active.isLocked)
        #expect(right.viewMode == .full)
    }

    /// What the program saves when it ends has the shape it was read in.
    @Test
    internal func thePanelsAreSavedInTheSameShape() async throws {
        let settings = Self.panelSettings()
        let (shell, kernel) = try await start(on: settings)
        shell.saveState()
        Self.stop(shell, kernel)
        #expect(SettingsMigrationShell.matches(settings.data(forKey: "left.tabs"), Fixture.leftTabs))
        #expect(SettingsMigrationShell.matches(settings.data(forKey: "right.tabs"), Fixture.rightTabs))
        // The widths of the columns are those the table has now; mode and columns are kept.
        let view = settings.value(PanelViewState.self, forKey: "left.view")
        #expect(view?.viewMode == .brief && view?.extraColumns == ["upper", "length"])
    }

    /// The colour list is shown one entry per line and stored joined by `;;`.
    ///
    /// The list of the versions before git is written in today's form, today's list as it was.
    @Test(
        arguments: [
            (SettingsMigrationShell.Fixture.colorRulesInLines, #""*.zip *.gz = purple;;*.app = green;;-*.tmp = red""#),
            (SettingsMigrationShell.Fixture.colorRules, SettingsMigrationShell.Fixture.colorRules)
        ])
    internal func theColoursAreSavedJoined(_ fixture: String, _ saved: String) async throws {
        let settings = SettingsMigrationShell.settings([
            PanelSettings.colorRulesKey: fixture, PanelSettings.colorsByTypeKey: "true"
        ])
        let (shell, kernel) = try await start(on: settings)
        defer { Self.stop(shell, kernel) }
        let left = shell.panelCoordinator.leftPanel
        #expect(left.settings.colorRules.count == 2)
        interaction.formAnswers = [.accept]
        kernel.commands.perform("afm_DefineColorsByFileType")
        #expect(SettingsMigrationShell.matches(settings.data(forKey: PanelSettings.colorRulesKey), saved))
        #expect(left.settings.colorRules.count == 2)
    }
}
