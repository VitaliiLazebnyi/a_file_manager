import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// Round 2 of the review, second pass, Configuration: parameters with extreme lengths, line ends in list files and
/// user commands found by name.
@Suite
internal struct Review2PluginsA2Configuration {
    /// Two panels, the left one with a selection of which one name holds a line separator (U+2028).
    internal let context = ExpansionContext(
        left: PanelSnapshot(path: "/A dir/", cursorName: "my file.txt", selection: ["a.txt", "b\u{2028}c.txt"]),
        right: PanelSnapshot(path: "/B/", cursorName: "other.md"),
        listFolder: URL(fileURLWithPath: "/tmp/lists"),
        listName: "test"
    )

    /// A substring of the largest or smallest length or start a number can hold expands to a short text and does
    /// not trap.
    @Test
    internal func aSubstringOfTheLargestLengthDoesNotTrap() {
        // The reproducer of the fuzzer (`pexpand-substring-length-overflow.bin`) and the same words by hand.
        let repro = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fuzz/repro/misc/pexpand-substring-length-overflow.bin")
        var texts = [
            "%N:~6,9223372036854775807", "%N:~9223372036854775807,9223372036854775807", "%N:~-9223372036854775808,5",
            "%N:~0,-9223372036854775808", "%N:~6,18446744073709551616"
        ]
        if let data = try? Data(contentsOf: repro), let text = String(bytes: data, encoding: .utf8) {
            texts.append(text)
        }
        for text in texts {
            let expanded = ParameterExpander(context: context).expand(text).text
            #expect(expanded.utf8.count < 200, "\(text)")
        }
        #expect(
            ParameterExpander(context: context).expand("%N:~6,9223372036854775807").text
                == ParameterExpander(context: context).expand("%N:~6,99").text
        )
    }

    /// A selected name with a line separator is not written to a list file: the expansion reports a problem.
    @Test
    internal func aNameWithAnyKindOfLineEndIsNotPassedInAListFile() {
        // U+2028 ends a line for the programs that read the list with `splitlines`.
        let expanded = ParameterExpander(context: context).expand("%L")
        #expect(expanded.problem != nil)
    }

    /// A user command is found by its name among many, the first of two with one name wins, and the index follows
    /// a new list.
    @Test
    internal func aUserCommandIsFoundByNameWithoutSearching() {
        let settings = MemorySettings()
        let store = ConfigurationStore(settings: settings)
        var commands: [UserCommand] = []
        for index in 0..<200 {
            commands.append(
                UserCommand(name: "em_\(index)", title: "", action: CommandAction(command: "echo \(index)"))
            )
        }
        commands.append(UserCommand(name: "em_7", title: "", action: CommandAction(command: "echo again")))
        store.userCommands = commands
        #expect(store.userCommand(named: "em_150")?.action.command == "echo 150")
        // Of two commands of one name the first is the one.
        #expect(
            store.userCommand(named: "em_7")?.action.command == "echo 7" && store.userCommand(named: "nothing") == nil
        )
        store.userCommands = Array(commands.prefix(3))
        #expect(
            store.userCommand(named: "em_150") == nil && store.userCommand(named: "em_1")?.action.command == "echo 1"
        )
    }
}
