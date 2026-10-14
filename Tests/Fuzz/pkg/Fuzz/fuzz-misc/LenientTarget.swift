import AFMKernel
import Foundation
import FuzzCore

@testable import ConfigurationPlugin

/// The `lenient` target: the lenient decoders of stored values, and each known key holding the input.
@MainActor
internal enum LenientTarget {
    /// Tokens of the stored values.
    private static let dictionary = [
        "\"name\"", "\"title\"", "\"action\"", "\"command\"", "\"parameters\"", "\"startPath\"", "\"symbol\"",
        "\"children\"", "\"kind\"", "\"item\"", "\"submenu\"", "\"separator\"", "\"entries\"", "\"hideCharacter\"",
        "\"hidesMarked\"", "\"visits\"", "\"location\"", "\"isVisible\"", "\"counts\"", "\"tabs\"", "\"active\"",
        "\"sortKey\"", "\"descending\"", "\"showHidden\"", "\"locked\"", "9223372036854775807",
        "-9223372036854775808", "1e400", "null", "true", "[]", "{}", "[[[[", "cmd+", "ctrl+", "opt+", "shift+",
        "f12", "f0", "num+", "\"file:///a/\"", "\"\"", "\\ud800", "\\u0000"
    ]

    /// The keys whose stored values are read leniently.
    private static let keys = [
        "keyBindings", "left.tabs", "right.tabs", "places.hotlist", "places.history.left", "places.history.right",
        "places.history.frequent", "configuration.userCommands", "configuration.startMenu", "configuration.symbols"
    ]

    /// The target.
    internal static func make() -> FuzzTarget {
        FuzzTarget("lenient", maxLen: 8_192, dict: dictionary, seeds: seeds, run: run)
    }

    /// A value of each kind of stored setting.
    private static func seeds() -> [[UInt8]] {
        seedTexts([
            "[{\"name\":\"em_a\",\"title\":\"A\",\"action\":{\"command\":\"ls\",\"parameters\":\"%S\"},"
                + "\"symbol\":\"s\"},{\"bad\":1},7]",
            "[{\"title\":\"One\",\"action\":{\"command\":\"ls\"}},{\"title\":\"-\"}]",
            "{\"cm_Exit\":[\"cmd+q\",\"f10\"],\"em_x\":[\"ctrl+opt+shift+cmd+a\",\"num*\",\"f13\"]}",
            "{\"tabs\":[{\"location\":\"file:///tmp/\",\"sortKey\":7,\"descending\":true,\"showHidden\":true,"
                + "\"title\":\"t\",\"locked\":true}],\"active\":9}",
            "{\"entries\":[{\"kind\":\"submenu\",\"title\":\"?s\",\"children\":[{\"kind\":\"item\",\"title\":\"x\","
                + "\"command\":\"cd /a/:\"},5]}],\"hideCharacter\":\"?\",\"hidesMarked\":true}",
            "{\"visits\":[{\"location\":\"file:///a/\",\"isVisible\":true},{\"location\":\"\"},3]}",
            "{\"counts\":{\"file:///a/\":2,\"file:///b/\":9223372036854775807}}", "\"cmd+shift+f5\""
        ])
    }

    /// Decodes the input as each kind of stored value, then stores it under every known key and uses it.
    private static func run(_ bytes: [UInt8]) {
        let data = Data(bytes)
        _ = try? JSONDecoder().decode(LenientList<UserCommand>.self, from: data)
        _ = try? JSONDecoder().decode(LenientList<StartMenuEntry>.self, from: data)
        if let text = try? JSONDecoder().decode(String.self, from: data) {
            if let shortcut = Shortcut(notation: text) {
                fzCheck(
                    Shortcut(notation: shortcut.notation) == shortcut,
                    "shortcut-notation-roundtrip",
                    "\(text.debugDescription) -> \(shortcut.notation.debugDescription)"
                )
            }
            _ = UserCommand.name(from: text)
        }
        // Each known key holds the input in turn.
        let store = MemorySettings()
        for key in keys {
            store.set(data as Data?, forKey: key)
        }
        store.set(data as Data?, forKey: KeyBindings.settingsKey)
        StoredSettingsUse.use(store)
        let configuration = ConfigurationStore(settings: store)
        for command in configuration.userCommands.prefix(20) {
            _ = command.caption
            _ = command.id
        }
        _ = configuration.startMenu
        _ = configuration.symbols
    }
}
