import AFMContracts
import AFMKernel
import AppKit
import Testing

@testable import AFMShell

@Suite struct SpeedAndTime {
    @Test func needsASecondOfMeasurements() {
        var rate = TransferRate()
        #expect(rate.perSecond == nil)
        rate.add(amount: 0, at: 10)
        rate.add(amount: 500, at: 10.5)
        #expect(rate.perSecond == nil)
        #expect(rate.remaining(total: 1_000) == nil)
        rate.add(amount: 2_000, at: 12)
        #expect(rate.perSecond == 1_000)
        #expect(rate.remaining(total: 5_000) == 3)
    }

    @Test func followsTheLastSecondsOnly() {
        var rate = TransferRate(window: 5)
        // 100 per second for 10 s, then 1000 per second for 5 s.
        for second in 0...10 { rate.add(amount: Int64(second * 100), at: Double(second)) }
        #expect(rate.perSecond == 100)
        for second in 11...15 { rate.add(amount: Int64(1_000 + (second - 10) * 1_000), at: Double(second)) }
        #expect(rate.perSecond == 1_000)
        #expect(rate.remaining(total: 16_000) == 10)
    }

    @Test func stalledAndFinishedJobs() {
        var rate = TransferRate()
        rate.add(amount: 500, at: 0)
        rate.add(amount: 500, at: 3)
        #expect(rate.perSecond == 0)
        #expect(rate.remaining(total: 1_000) == nil)
        rate.add(amount: 1_000, at: 4)
        #expect(rate.remaining(total: 1_000) == 0)
        rate.reset()
        #expect(rate.perSecond == nil)
    }

    @Test func progressLine() {
        var rate = TransferRate()
        let copying = JobProgress(
            lines: ["From: a", "To: b"],
            itemsDone: 1,
            itemsTotal: 4,
            bytesDone: 20 << 20,
            bytesTotal: 100 << 20
        )
        #expect(ProgressSheet.speedLine(rate, for: copying) == "Calculating…")
        rate.add(amount: 0, at: 0)
        rate.add(amount: 20 << 20, at: 2)
        #expect(ProgressSheet.speedLine(rate, for: copying) == "10.00 M/s  ·  about 8 s left")

        // A job that moves no data is measured in items and shows only the time.
        var items = TransferRate()
        let deleting = JobProgress(lines: ["Deleting: a"], itemsDone: 10, itemsTotal: 40)
        items.add(amount: 0, at: 0)
        items.add(amount: 10, at: 2)
        #expect(ProgressSheet.speedLine(items, for: deleting) == "about 6 s left")
    }
}

@MainActor @Suite struct KeysAndMenus {
    func keyEvent(_ keyCode: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test func keyPressesBecomeShortcuts() {
        #expect(Shortcut.candidates(for: keyEvent(96)) == [.f(5)])
        #expect(Shortcut.candidates(for: keyEvent(97, "", .shift)) == [.f(6, .shift)])
        #expect(
            Shortcut.candidates(for: keyEvent(123, "", [.option, .numericPad, .function])) == [
                Shortcut(.left, .option)
            ]
        )
        #expect(Shortcut.candidates(for: keyEvent(8, "c", .command)) == [.cmd("c")])
        #expect(Shortcut.candidates(for: keyEvent(8, "C", [.command, .shift])) == [.cmd("c", .shift)])
        #expect(Shortcut.candidates(for: keyEvent(69, "+", .numericPad)) == [Shortcut(.keypadPlus)])
        #expect(Shortcut(.space).matches(keyEvent(49, " ")) && !Shortcut(.space).matches(keyEvent(49, " ", .shift)))
    }

    @Test func aKeyPressFindsItsCommand() {
        let keys = KeyBindings()
        keys.bindDefault(.f(5), to: "copy")
        keys.bindDefault(.cmd("r"), to: "reread")
        #expect(keys.command(for: keyEvent(96)) == "copy")
        #expect(keys.command(for: keyEvent(15, "r", .command)) == "reread")
        #expect(keys.command(for: keyEvent(15, "r")) == nil)
    }

    @Test func onlySafeShortcutsGoIntoMenus() {
        #expect(Shortcut.f(5).isMenuSafe && Shortcut.f(6, .shift).isMenuSafe)
        #expect(Shortcut.cmd("c").isMenuSafe && Shortcut(.tab, .control).isMenuSafe)
        // Plain typing keys must stay with text fields; the keypad cannot be shown in a menu.
        #expect(!Shortcut(.returnKey).isMenuSafe && !Shortcut(.space).isMenuSafe && !Shortcut(.backspace).isMenuSafe)
        #expect(!Shortcut(.left).isMenuSafe && !Shortcut(.keypadPlus, .control).isMenuSafe)
    }

    @Test func menuItemsTakeCaptionFromTheCommandAndKeyFromTheBindings() {
        let keys = KeyBindings()
        let commands = CommandRegistry(keyBindings: keys)
        commands.register(Command("cm_Copy", "Copy…", [Shortcut(.returnKey), .f(5), .cmd("k")])) {}
        commands.register(Command("cm_Paste", "Paste", [.cmd("v")]).editing(.paste)) {}
        let item = MenuBuilder.item(commands["cm_Copy"]!, keys: keys)
        #expect(item.title == "Copy…")
        #expect(
            item.keyEquivalent == String(UnicodeScalar(UInt32(NSF5FunctionKey))!)
                && item.keyEquivalentModifierMask.isEmpty
        )
        #expect(MenuBuilder.command(of: item) == "cm_Copy")
        let paste = MenuBuilder.item(commands["cm_Paste"]!, keys: keys)
        #expect(paste.action == #selector(NSText.paste(_:)) && paste.keyEquivalentModifierMask == .command)
        // A context menu shows no keys; a rebound command shows its new key.
        #expect(MenuBuilder.item(commands["cm_Copy"]!, keys: nil).keyEquivalent.isEmpty)
        keys.apply(overrides: ["cm_Copy": ["f9"]])
        #expect(
            MenuBuilder.item(commands["cm_Copy"]!, keys: keys).keyEquivalent
                == String(UnicodeScalar(UInt32(NSF9FunctionKey))!)
        )
    }

    @Test func menusSkipUnregisteredNamesAndDoubleSeparators() {
        let commands = CommandRegistry()
        commands.register(Command("a", "A")) {}
        commands.register(Command("b", "B")) {}
        let menu = MenuBuilder.menu("Test", [nil, "a", nil, "missing", nil, "b", nil], commands: commands, keys: nil)
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title } == ["A", "-", "B"])
    }

    @Test func modifiersConvertBothWays() {
        let all: KeyModifiers = [.shift, .control, .option, .command]
        #expect(KeyModifiers(all.eventFlags) == all)
        #expect(KeyModifiers([.shift, .capsLock, .function]) == .shift)
    }

    @Test func statusLine() {
        let totals = PanelModel.Totals(
            selectedBytes: 5 * 1_024,
            totalBytes: 8 * 1_024,
            selectedFiles: 4,
            totalFiles: 14
        )
        #expect(PanelViewController.statusText(totals) == "5 k / 8 k in 4 / 14 file(s)")
        let withFolders = PanelModel.Totals(totalFiles: 0, totalFolders: 2)
        #expect(PanelViewController.statusText(withFolders) == "0 k / 0 k in 0 / 0 file(s), 0 / 2 dir(s)")
        #expect(PanelViewController.statusText(totals, itemsSoFar: 12_000).hasPrefix("Loading… 12,000 items so far"))
    }
}
