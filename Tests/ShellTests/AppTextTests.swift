import AFMContracts
import AFMKernel
import AppKit
import Testing

@testable import AFMShell

/// What the program writes: names cleaned for display, keys as the Mac writes them, menus as
/// long as the screen allows.
@MainActor
@Suite
internal struct AppTextTests {
    /// Control characters, the delete character and direction marks show as visible signs.
    @Test
    internal func invisibleCharactersShowAsSigns() {
        #expect(DisplayText.clean("a\u{7F}b") == "a\u{2421}b")
        #expect(DisplayText.clean("a\u{1B}b\nc") == "a\u{241B}b\u{240A}c")
        #expect(DisplayText.clean("a\nb", keepingLines: true) == "a\nb")
        #expect(DisplayText.clean("x\u{202E}y") == "x\u{FFFD}y")
        #expect(DisplayText.clean("plain") == "plain")
    }

    /// Every named key has the sign the Mac's menus give it, behind the modifiers in the Mac's order.
    @Test
    internal func everyNamedKeyHasItsSign() {
        let signs: [(Key, String)] = [
            (.returnKey, "↩"), (.enter, "⌤"), (.tab, "⇥"), (.space, "Space"), (.backspace, "⌫"),
            (.forwardDelete, "⌦"), (.insert, "Ins"), (.home, "↖"), (.end, "↘"), (.pageUp, "⇞"), (.pageDown, "⇟"),
            (.leftArrow, "←"), (.rightArrow, "→"), (.upArrow, "↑"), (.downArrow, "↓"), (.keypadPlus, "Num +"),
            (.keypadMinus, "Num −"), (.keypadMultiply, "Num ×"), (.keypadDivide, "Num ÷"), (.function(12), "F12"),
            (.character("q"), "Q")
        ]
        for (key, sign) in signs {
            #expect(Shortcut(key, []).displayText == sign)
        }
        #expect(Shortcut(.tab, [.command, .option, .control, .shift]).displayText == "⌃⌥⇧⌘⇥")
    }

    /// A menu shows as many entries as fit on the screen, at least twenty; without a screen 36.
    @Test
    internal func aMenuIsAsLongAsTheScreenAllows() {
        #expect(MenuBuilder.limit(forScreenHeight: nil) == 36)
        #expect(MenuBuilder.limit(forScreenHeight: 1_100) == 48)
        #expect(MenuBuilder.limit(forScreenHeight: 300) == 20)
        #expect(MenuBuilder.screenLimit >= 20)
    }

    /// The command that has an editing role is found by it; a role nobody took has none.
    @Test
    internal func aCommandIsFoundByItsEditingRole() {
        let commands = CommandRegistry()
        commands.register(Command("cm_Paste", "Paste").editing(.paste)) {
            // Nothing to do: the command only has to be found.
        }
        #expect(commands.command(with: .paste) == "cm_Paste")
        #expect(commands.command(with: .cut) == nil)
    }
}
