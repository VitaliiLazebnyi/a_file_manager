import AFMKernel
import TestSupport
import Testing

/// Shortcuts and key bindings: their notation, the commands' default keys and the user's own.
@MainActor
@Suite
internal struct KeyTests {
    /// Every shortcut writes itself in its notation and is read back from it; case and order
    /// of the modifiers do not matter, and nonsense is refused.
    @Test
    internal func shortcutsAsText() {
        let samples: [(Shortcut, String)] = [
            (.cmd("c", .shift), "shift+cmd+c"), (.f(5), "f5"), (.f(6, .shift), "shift+f6"),
            (Shortcut(.tab, .control), "ctrl+tab"),
            (Shortcut(.left, .option), "opt+left"), (Shortcut(.keypadPlus), "num+"),
            (Shortcut(.keypadPlus, .control), "ctrl+num+"),
            (.cmd("="), "cmd+="), (.cmd("+"), "cmd++"), (Shortcut(.space), "space"),
            (Shortcut(.forwardDelete, .shift), "shift+delete")
        ]
        for (shortcut, text) in samples {
            #expect(shortcut.notation == text)
            #expect(Shortcut(notation: text) == shortcut)
        }
        #expect(Shortcut(notation: "CMD+Shift+C") == .cmd("c", .shift))
        #expect(Shortcut(notation: "cmd+shift+c") == Shortcut(notation: "shift+cmd+c"))
        #expect(Shortcut(notation: "f13") == nil)
        #expect(Shortcut(notation: "") == nil)
        #expect(Shortcut(notation: "cmd+nonsense") == nil)
    }

    /// Registering a command binds its default keys, without conflicts.
    @Test
    internal func commandsBringTheirDefaultKeys() {
        let keys = KeyBindings()
        let commands = CommandRegistry(keyBindings: keys)
        commands.register(Command("copy", "Copy", [.f(5), .cmd("k")])) {
            // Not run here.
        }
        commands.register(Command("view", "View", [.f(3)])) {
            // Not run here.
        }
        #expect(keys.command(for: .f(5)) == "copy" && keys.command(for: .cmd("k")) == "copy")
        #expect(keys.shortcuts(for: "copy") == [.f(5), .cmd("k")])
        #expect(keys.command(for: .f(9)) == nil && keys.conflicts.isEmpty)
    }

    /// The first command to ask for a key keeps it; a later one is refused and the conflict noted once.
    @Test
    internal func aKeyTakenTwiceStaysWithTheFirstAndIsReported() {
        let keys = KeyBindings()
        keys.bindDefault(.f(5), to: "copy")
        keys.bindDefault(.f(5), to: "pack")
        keys.bindDefault(.f(5), to: "copy")
        #expect(keys.command(for: .f(5)) == "copy")
        #expect(keys.conflicts == [KeyBindings.Conflict(shortcut: .f(5), kept: "copy", rejected: "pack")])
        #expect(keys.shortcuts(for: "pack").isEmpty)
    }

    /// Keys from the settings win over the defaults: they move a key from one command to
    /// another, and unreadable ones are skipped.
    @Test
    internal func theUsersBindingsReplaceTheDefaults() {
        let keys = KeyBindings()
        keys.bindDefault(.f(5), to: "copy")
        keys.bindDefault(.cmd("k"), to: "copy")
        keys.bindDefault(.f(6), to: "move")
        let settings = MemorySettings()
        settings.set(["move": ["f5", "ctrl+m", "nonsense+"], "view": ["f6"]], forKey: KeyBindings.settingsKey)
        keys.load(from: settings)
        // Move takes F5 away from Copy and gives up F6, which View takes; Copy keeps its other key.
        #expect(keys.command(for: .f(5)) == "move" && keys.command(for: Shortcut(.character("m"), .control)) == "move")
        #expect(keys.shortcuts(for: "move") == [.f(5), Shortcut(.character("m"), .control)])
        #expect(keys.shortcuts(for: "copy") == [.cmd("k")])
        #expect(keys.command(for: .f(6)) == "view")
    }
}
