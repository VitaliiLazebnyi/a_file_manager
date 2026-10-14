import AFMKernel
import Foundation
import FuzzCore
import TestSupport

@testable import ConfigurationPlugin

/// The `settings` target: a settings import (every part ticked), the commands it brought, and an export.
@MainActor
internal enum SettingsTarget {
    /// Tokens of a settings file.
    private static let dictionary = [
        "\"format\"", "\"A File Manager settings\"", "\"settings\"", "\"$data\"", "\"configuration.userCommands\"",
        "\"configuration.startMenu\"", "\"configuration.symbols\"", "\"keyBindings\"", "\"left.tabs\"",
        "\"places.hotlist\"", "\"places.history.frequent\"", "\"counts\"", "\"visits\"", "\"name\"", "\"action\"",
        "\"command\"", "\"parameters\"", "\"startPath\"", "\"children\"", "\"kind\"", "\"submenu\"", "\"active\"",
        "\"sortKey\"", "9223372036854775807", "-9223372036854775808", "1e400", "null", "true", "[]", "{}",
        "[[[[[[[[", "\"em_\"", "%S", "%N:~1,9223372036854775807", "\"%S%E\"", "%|HOME|", "%A-1-", "%B+9", "%C2",
        "%UL", "cm_wait -5", "cd ", "\\u0000", "\\ud800"
    ]

    /// Every part of an import ticked.
    private static let ticked: [String: FormValues.Value] = [
        "commands": .flag(true), "keys": .flag(true), "programs": .flag(true), "trust": .flag(true),
        "connections": .flag(true), "hotlist": .flag(true), "tabs": .flag(true)
    ]

    /// The target.
    internal static func make() -> FuzzTarget {
        FuzzTarget("settings", maxLen: 8_192, dict: dictionary, seeds: SettingsSeeds.all, run: run)
    }

    /// Imports the input twice, runs what it brought, uses what was stored and exports it again.
    private static func run(_ bytes: [UInt8]) {
        let bench = SettingsBench()
        guard let center = bench.plugin.center else {
            fzFail("settings-no-center")
        }
        let url = URL(fileURLWithPath: fzWorkDir + "/import.json")
        try? Data(bytes).write(to: url)
        importTwice(url, bench: bench, center: center, answer: bytes.count % 8)
        if ProcessInfo.processInfo.environment["FZ_VERBOSE"] != nil {
            report(url, bench: bench, center: center)
        }
        _ = center.commandRows()
        _ = center.startMenuSections()
        _ = center.startMenuDraft()
        runImportedCommands(bench: bench, center: center)
        _ = bench.plugin.launched
        StoredSettingsUse.use(bench.settings)
        // Exported again, the file can be read.
        let archive = SettingsArchive.capture(from: bench.settings, keys: center.settingsKeys())
        if let out = try? archive.encoded() {
            do {
                _ = try SettingsArchive(data: out)
            } catch {
                fzFail("settings-export-unreadable", "\(error)")
            }
        }
    }

    /// Imports the file, answering the form as `answer` says, then once more with everything ticked.
    ///
    /// An import shows a form and does nothing unless it is answered. Mostly every part is ticked
    /// (commands, key bindings, programs, trust, connections, hotlist, tabs), so that all of the file
    /// that passes the checks is stored; sometimes it is accepted as proposed, sometimes cancelled.
    private static func importTwice(_ url: URL, bench: SettingsBench, center: ConfigurationCenter, answer: Int) {
        switch answer {
        case 0:
            bench.bench.interaction.formAnswers = [.accept]

        case 1:
            bench.bench.interaction.formAnswers = []

        default:
            bench.bench.interaction.formAnswers = [.values(ticked)]
        }
        center.importSettings(from: url)
        // A second import of the same file, everything ticked: nothing may be left half done by the first.
        bench.bench.interaction.formAnswers = [.values(ticked)]
        center.importSettings(from: url)
    }

    /// To see how far an input gets (FZ_VERBOSE): what the program said, and what was stored.
    private static func report(_ url: URL, bench: SettingsBench, center: ConfigurationCenter) {
        do {
            _ = try CheckedSettings(SettingsArchive(data: CheckedSettings.read(url)), schema: center.settingsSchema())
        } catch {
            print("refused: \(error)")
        }
        let keysStored = bench.settings.data(forKey: KeyBindings.settingsKey) != nil
        let frequentStored = bench.settings.data(forKey: "places.history.frequent") != nil
        print(
            "ui: \(bench.bench.interaction.log)\nforms shown: \(bench.bench.interaction.forms.count); "
                + "user commands \(center.store.userCommands.count), start menu \(center.store.startMenu.count), "
                + "key bindings stored \(keysStored), frequent \(frequentStored)"
        )
    }

    /// The commands the file brought are run (nothing is launched: the lines are collected).
    private static func runImportedCommands(bench: SettingsBench, center: ConfigurationCenter) {
        bench.bench.left.moveCursor(toName: "my file.txt")
        let userCommands = center.store.userCommands.map { ($0.id, $0.action) }
        let startMenu = center.store.startMenu.enumerated()
            .map { entry in
                (StartMenuEntry.commandID(at: entry.offset), entry.element.action)
            }
        for (id, action) in (userCommands + startMenu).prefix(24) {
            let lowered = action.command.lowercased()
            _ = CommandLanguage.steps(action.command, environment: ["HOME": "/Users/x y"]) { _ in nil }
            // Commands of the program are not performed (some open windows); programs and shell lines are.
            let isProgramCommand =
                lowered.contains("cm_") || lowered.contains("em_") || lowered.contains("afm_")
                || lowered.hasPrefix("cd")
            if isProgramCommand {
                continue
            }
            bench.bench.kernel.commands.perform(id)
        }
    }
}
