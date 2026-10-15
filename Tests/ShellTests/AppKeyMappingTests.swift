import AFMContracts
import AFMKernel
import AppKit
import Testing

@testable import AFMShell

/// Key presses as the Mac delivers them and the shortcuts of the kernel, both ways.
@MainActor
@Suite
internal struct AppKeyMappingTests {
    /// A key press becomes the shortcuts it can stand for, function keys and the keypad included.
    @Test
    internal func keyPressesBecomeShortcuts() throws {
        #expect(Shortcut.candidates(for: try AppRun.keyEvent(96, "", [])) == [.f(5)])
        #expect(Shortcut.candidates(for: try AppRun.keyEvent(97, "", .shift)) == [.f(6, .shift)])
        #expect(
            Shortcut.candidates(for: try AppRun.keyEvent(123, "", [.option, .numericPad, .function])) == [
                Shortcut(.leftArrow, .option)
            ]
        )
        #expect(Shortcut.candidates(for: try AppRun.keyEvent(8, "c", .command)) == [.cmd("c")])
        #expect(Shortcut.candidates(for: try AppRun.keyEvent(8, "C", [.command, .shift])) == [.cmd("c", .shift)])
        #expect(Shortcut.candidates(for: try AppRun.keyEvent(69, "+", .numericPad)) == [Shortcut(.keypadPlus)])
        #expect(Shortcut(.space).matches(try AppRun.keyEvent(49, " ", [])))
        #expect(!Shortcut(.space).matches(try AppRun.keyEvent(49, " ", .shift)))
    }

    /// The bindings find the command of a key press, and nothing for a key bound to none.
    @Test
    internal func aKeyPressFindsItsCommand() throws {
        let keys = KeyBindings()
        keys.bindDefault(.f(5), to: "copy")
        keys.bindDefault(.cmd("r"), to: "reread")
        #expect(keys.command(for: try AppRun.keyEvent(96, "", [])) == "copy")
        #expect(keys.command(for: try AppRun.keyEvent(15, "r", .command)) == "reread")
        #expect(keys.command(for: try AppRun.keyEvent(15, "r", [])) == nil)
    }

    /// Plain typing keys stay with text fields, and the keypad cannot be shown in a menu.
    @Test
    internal func onlySafeShortcutsGoIntoMenus() {
        #expect(Shortcut.f(5).isMenuSafe && Shortcut.f(6, .shift).isMenuSafe)
        #expect(Shortcut.cmd("c").isMenuSafe && Shortcut(.tab, .control).isMenuSafe)
        #expect(!Shortcut(.returnKey).isMenuSafe && !Shortcut(.space).isMenuSafe && !Shortcut(.backspace).isMenuSafe)
        #expect(!Shortcut(.leftArrow).isMenuSafe && !Shortcut(.keypadPlus, .control).isMenuSafe)
    }

    /// The four modifiers convert both ways; Caps Lock and Fn are no modifiers of a shortcut.
    @Test
    internal func modifiersConvertBothWays() {
        let all: KeyModifiers = [.shift, .control, .option, .command]
        #expect(KeyModifiers(all.eventFlags) == all)
        #expect(KeyModifiers([.shift, .capsLock, .function]) == .shift)
    }

    /// Shortcuts are written as the Mac's menus write them.
    @Test
    internal func shortcutsAsTheMacWritesThem() {
        #expect(Shortcut.f(5).displayText == "F5" && Shortcut.f(6, [.shift, .control]).displayText == "⌃⇧F6")
        #expect(Shortcut.cmd("c", .shift).displayText == "⇧⌘C" && Shortcut(.returnKey, .control).displayText == "⌃↩")
        #expect(Shortcut(.downArrow, .option).displayText == "⌥↓" && Shortcut(.keypadPlus).displayText == "Num +")
    }

    /// The status line of a panel counts the marked and all files, folders when there are any.
    @Test
    internal func statusLine() {
        let totals = PanelModel.Totals(
            selected: PanelModel.Counts(bytes: 5 * 1_024, files: 4),
            total: PanelModel.Counts(bytes: 8 * 1_024, files: 14)
        )
        #expect(PanelViewController.statusText(totals) == "5 k / 8 k in 4 / 14 file(s)")
        let withFolders = PanelModel.Totals(total: PanelModel.Counts(folders: 2))
        #expect(PanelViewController.statusText(withFolders) == "0 k / 0 k in 0 / 0 file(s), 0 / 2 dir(s)")
        #expect(PanelViewController.statusText(totals, itemsSoFar: 12_000).hasPrefix("Loading… 12,000 items so far"))
    }
}
