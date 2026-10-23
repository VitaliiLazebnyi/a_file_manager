import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The runner: names that are not there, real paths of virtual listings, key bindings of deleted commands.
@MainActor
@Suite
internal struct ConfigPlacesFixRunner {
    /// The folders `A` (holding `one.txt`) and `B`.
    internal let box: Sandbox
    /// The settings of the program.
    internal let settings = MemorySettings()
    /// The plugin, which records what it would launch instead of launching it.
    internal let plugin: ConfigurationPlugin
    /// The program the plugin runs in, `A` on the left and `B` on the right.
    internal let bench: TestBench
    /// The plugin's configuration, there once the plugin has started.
    internal let center: ConfigurationCenter

    /// The bench over the two folders, with the plugin started.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt")
        try box.folder("B")
        plugin = ConfigurationPlugin(launchesApplications: false, background: nil, listFolder: box.url("lists")) {
            []
        }
        bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
        center = try #require(plugin.center)
    }

    /// A command whose parameters name the file under the cursor does not run on `[..]`; the user is told.
    @Test
    internal func aCommandWithANameCodeDoesNotRunWithoutAName() {
        center.save(
            UserCommand(name: "em_rm", title: "", action: CommandAction(command: "rm -rf", parameters: "%P%N"))
        )
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform("em_rm")
        #expect(plugin.launched.count == 1)
        // The cursor on [..]: nothing runs, the user is told.
        bench.left.model.cursor = 0
        if bench.left.model.cursorItem == nil {
            bench.commands.perform("em_rm")
            #expect(plugin.launched.count == 1 && bench.interaction.log.last == "inform: “rm” needs a file")
        }
    }

    /// Removing a user command removes its key binding from the settings.
    @Test
    internal func aDeletedUserCommandLeavesNoKeyBehind() {
        center.save(UserCommand(name: "em_k", title: "", action: CommandAction(command: "ls")))
        #expect(center.setShortcut("ctrl+shift+k", for: CommandID("em_k")))
        #expect(settings.value([String: [String]].self, forKey: KeyBindings.settingsKey)?["em_k"] == ["ctrl+shift+k"])
        center.removeUserCommand(named: "em_k")
        #expect(settings.data(forKey: KeyBindings.settingsKey) == nil)
    }

    /// The keyboard editor, rebased, keeps a binding stored elsewhere while its own edit is pending.
    @Test
    internal func theKeyboardEditorKeepsBindingsStoredElsewhere() {
        let editor = KeyBindingEditor(kernel: bench.kernel)
        editor.set([Shortcut(.character("j"), [.control])], for: CommandID("cm_SelectAll"))
        // The Start menu stores a key while the Keyboard page has an edit pending.
        center.save(UserCommand(name: "em_other", title: "", action: CommandAction(command: "ls")))
        #expect(center.setShortcut("ctrl+shift+o", for: CommandID("em_other")))
        editor.rebase(kernel: bench.kernel)
        editor.commit(to: settings, keyBindings: bench.kernel.keyBindings)
        let stored = settings.value([String: [String]].self, forKey: KeyBindings.settingsKey)
        #expect(stored?["em_other"] == ["ctrl+shift+o"] && stored?["cm_SelectAll"] == ["ctrl+j"])
    }
}
