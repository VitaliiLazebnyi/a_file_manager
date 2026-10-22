import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The placeholders of a Parameters field (spec 18 › Button and command parameters).
@Suite
internal struct ParameterExpansion {
    internal let context = ExpansionContext(
        left: PanelSnapshot(path: "/A dir/", cursorName: "my file.txt", selection: ["a.txt", "b c.txt", "d.tar.gz"]),
        right: PanelSnapshot(path: "/B/", cursorName: "other.md"),
        environment: ["HOME": "/Users/me", "Q": "\"quoted\""],
        arguments: "one \"two words\" three",
        listFolder: URL(fileURLWithPath: "/tmp/lists"),
        listName: "test"
    )

    internal func expand(_ text: String, _ change: (inout ExpansionContext) -> Void = { _ in }) -> String {
        var context = context
        change(&context)
        return ParameterExpander(context: context).expand(text).text
    }

    internal let unselected: (inout ExpansionContext) -> Void = { $0.left.selection = [] }

    @Test
    internal func singleValues() {
        #expect(expand("%P") == "\"/A dir/\"" && expand("%T") == "/B/")
        #expect(expand("%N") == "\"my file.txt\"" && expand("%M") == "other.md")
        #expect(expand("%O") == "\"my file\"" && expand("%E") == "txt")
        // The lower-case codes insert the same: the Mac has no short names.
        #expect(
            expand("%p%n") == expand("%P%N") && expand("%t%m") == "/B/other.md" && expand("%o.%e") == "\"my file\".txt"
        )
        #expect(expand("%v") == "\"my file.txt\"" && expand("%V") == "\"/A dir/my file.txt\"")
        #expect(expand("100%% %|HOME|/x %|NONE|.") == "100% /Users/me/x .")
        // A variable's value is quoted like any other: it stays one word whatever it holds.
        #expect(expand("%|Q| %q%|Q| %q%|Q|") == "\"\\\"quoted\\\"\" quoted \"\\\"quoted\\\"\"")
        #expect(expand("-o %J %") == "-o %J %")
        // A value that is empty and a word of its own stays a word: the later ones keep their places.
        #expect(expand("%N %M") { $0.left.cursorName = nil } == "\"\" other.md")
    }

    @Test
    internal func namesWithSpacesAreQuotedAsOneWord() {
        #expect(expand("open %P%N --to %T%M") == "open \"/A dir/my file.txt\" --to /B/other.md")
        // Quotes the user wrote are kept and not doubled.
        #expect(expand("\"%P%N\"") == "\"/A dir/my file.txt\"" && expand("x=\"%N\"") == "x=\"my file.txt\"")
        // %Q leaves the quoting to the user.
        #expect(expand("%Q%P%N") == "/A dir/my file.txt" && expand("%S%Q") == "a.txt b c.txt d.tar.gz")
        // What the shell would interpret is quoted and escaped too.
        #expect(expand("%N") { $0.left.cursorName = "a$b\"c.txt" } == "\"a\\$b\\\"c.txt\"")
        #expect(
            expand("%N") { $0.left.cursorName = "x=1" } == "\"x=1\""
                && expand("%N") { $0.left.cursorName = "plain-1_2.txt" } == "plain-1_2.txt"
        )
        #expect(
            ShellWords.unquoted("\"a\\$b\\\"c d\"") == "a$b\"c d"
                && ShellWords.split("a \"b c\" d") == ["a", "\"b c\"", "d"]
        )
    }

    @Test
    internal func selectedNames() {
        #expect(expand("%S") == "a.txt \"b c.txt\" d.tar.gz" && expand("%s") == expand("%S"))
        #expect(expand("%P%S") == "\"/A dir/a.txt\" \"/A dir/b c.txt\" \"/A dir/d.tar.gz\"")
        #expect(expand("%T%S1") == "/B/a.txt")
        #expect(expand("%R") == "other.md" && expand("%T%R") == "/B/other.md")
        #expect(expand("%R") { $0.right.selection = ["x", "y z"] } == "x \"y z\"")
        // Nothing selected: the file under the cursor, unless %Y asks for nothing.
        #expect(expand("ls %S", unselected) == "ls \"my file.txt\"" && expand("ls %Y%S", unselected) == "ls")
        // Ranges.
        #expect(
            expand("%S2") == "a.txt \"b c.txt\"" && expand("%S+2") == "\"b c.txt\""
                && expand("%S+2-3") == "\"b c.txt\" d.tar.gz"
        )
        #expect(
            expand("%S+2-") == "\"b c.txt\" d.tar.gz" && expand("%S-1") == "d.tar.gz"
                && expand("%S-3-2") == "a.txt \"b c.txt\""
        )
        #expect(
            expand("%S-2-") == "\"b c.txt\" d.tar.gz" && expand("%S+9") == ""
                && expand("%S -x") == "a.txt \"b c.txt\" d.tar.gz -x"
        )
        // In the user's quotes every name gets its own pair, with the text around as affixes.
        #expect(expand("\"%S\"") == "\"a.txt\" \"b c.txt\" \"d.tar.gz\"")
        #expect(expand("cp \"%P%S\" x") == "cp \"/A dir/a.txt\" \"/A dir/b c.txt\" \"/A dir/d.tar.gz\" x")
        #expect(
            expand("\"new-%S-old%E.bak\"") == "\"new-a-old.txt.bak\" \"new-b c-old.txt.bak\" \"new-d.tar-old.gz.bak\""
        )
        #expect(expand("\"%S.bak\"") == "\"a.txt.bak\" \"b c.txt.bak\" \"d.tar.gz.bak\"")
    }

    @Test
    internal func substrings() {
        #expect(
            expand("%E:~0,2") == "tx" && expand("%E:~1") == "xt" && expand("%E:~-2") == "xt"
                && expand("%E:~-2,1") == "x"
        )
        #expect(expand("%P:~0,-1") == "\"/A dir\"" && expand("%E:~1,1~2") == "x2" && expand("%E:~9") == "\"\"")
        // -0: the name without its extension, or the extension.
        #expect(expand("%N:~-0,2") == "my" && expand("%N:~-0,-2") == "tx" && expand("%N:~-0") == "\"my file\"")
        // With a path in front, the substring is taken from the name.
        #expect(expand("%T%S:~0,1") == "/B/a /B/b /B/d")
        #expect(expand("%E:x %E:~") == "txt:x txt:~")
    }

    @Test
    internal func directoriesComparedFilesAndSides() {
        let deep: (inout ExpansionContext) -> Void = { $0.left.path = "/Users/me/Projects/app/" }
        #expect(expand("%B", deep) == "app" && expand("%B0 %B1 %B2 %B9", deep) == "app Projects me \"\"")
        #expect(expand("%B-1", deep) == "Projects" && expand("%B+1 %B+3 %B+ [%B+0]", deep) == "Users Projects / []")
        #expect(expand("%BT %BT1") == "B \"\"")
        #expect(expand("%C1 %C2 %C3 %C4") == "\"/A dir/a.txt\" \"/A dir/b c.txt\" \"/A dir/d.tar.gz\" \"\"")
        // Fewer than two selected: the second file is the one of the same name on the other side.
        #expect(expand("%C1 %C2", unselected) == "\"/A dir/my file.txt\" \"/B/my file.txt\"")
        #expect(
            expand("%C1 %C2") {
                $0.left.selection = []
                $0.right.selection = ["r.txt"]
            } == "\"/A dir/my file.txt\" /B/r.txt"
        )
        // The right panel is the source: source and target swap, %X names the sides themselves.
        let rightActive: (inout ExpansionContext) -> Void = { $0.sourceIsRight = true }
        #expect(
            expand("%P %T", rightActive) == "/B/ \"/A dir/\""
                && expand("%X%P %T %x%P", rightActive) == "\"/A dir/\" /B/ /B/"
        )
        #expect(expand("%X%N %M %S1 %R") == "\"my file.txt\" other.md a.txt other.md")
        #expect(expand("%C1 %C2", rightActive) == "\"/A dir/a.txt\" /B/other.md")
    }

    @Test
    internal func argumentsOfAUserCommand() {
        #expect(expand("%A") == "one \"two words\" three" && expand("%q%A") == "one two words three")
        #expect(expand("/L=%A1 /R=%A2") == "/L=one /R=\"two words\"")
        #expect(
            expand("%A-1 %A2+ [%A2-] %A1-2 %A-3-2 %A-2- %A9")
                == "three \"two words\" three [\"two words\" three] one \"two words\" one \"two words\" \"two words\" three"
        )
        #expect(
            ParameterExpander(context: context).expand("%A1").usedArguments
                && !ParameterExpander(context: context).expand("%N").usedArguments
        )
    }

    @Test
    internal func aLeadingQuestionMarkAsksFirst() {
        let asked = ParameterExpander(context: context).expand("?-v %N")
        #expect(asked.asksFirst && asked.text == "-v \"my file.txt\"")
        #expect(!ParameterExpander(context: context).expand("-v ?").asksFirst)
    }

    @Test
    internal func listFilesAreWrittenToTheListFolder() throws {
        let box = try Sandbox()
        func list(_ text: String, _ change: (inout ExpansionContext) -> Void = { _ in }) throws -> (
            text: String, written: Data?
        ) {
            var context = context
            context.listFolder = box.url("lists")
            change(&context)
            let result = ParameterExpander(context: context).expand(text)
            guard let file = result.listFile else {
                return (result.text, nil)
            }
            try FileManager.default.createDirectory(
                at: file.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.contents.write(to: file.url)
            #expect(file.url == box.url("lists/list-test.txt"))
            return (result.text, try Data(contentsOf: box.url("lists/list-test.txt")))
        }
        let path = box.url("lists/list-test.txt").path
        let withPaths = try list("tar -T %L")
        #expect(
            withPaths.text == "tar -T " + path
                && withPaths.written == Data("/A dir/a.txt\n/A dir/b c.txt\n/A dir/d.tar.gz\n".utf8)
        )
        #expect(try list("%F").written == Data("a.txt\nb c.txt\nd.tar.gz\n".utf8))
        #expect(
            try list("%l").written == withPaths.written && list("%D").written == withPaths.written
                && list("%d").written == list("%f").written
        )
        #expect(try list("%UF").written == Data([0xEF, 0xBB, 0xBF]) + Data("a.txt\nb c.txt\nd.tar.gz\n".utf8))
        let wide = try #require(try list("%WL", unselected).written)
        #expect(
            wide.prefix(2) == Data([0xFF, 0xFE])
                && String(data: wide.dropFirst(2), encoding: .utf16LittleEndian) == "/A dir/my file.txt\n"
        )
        // The target panel's selection is added with %a; only the first list of a command counts.
        #expect(
            try list("%a%L") { $0.right.selection = ["r.txt"] }.written
                == Data("/A dir/a.txt\n/A dir/b c.txt\n/A dir/d.tar.gz\n/B/r.txt\n".utf8)
        )
        #expect(try list("%F %L").text == path)
        // Nothing selected: the cursor file; %Y an empty list; %y no list parameter at all.
        #expect(try list("%F", unselected).written == Data("my file.txt\n".utf8))
        #expect(try list("%Y%F", unselected).written == Data())
        let dropped = try list("-x %y%L", unselected)
        #expect(dropped.text == "-x" && dropped.written == nil)
        #expect(try list("%Y%y%F", unselected).written == Data("my file.txt\n".utf8))
        #expect(
            try list("%Y%y%F") {
                $0.left.selection = []
                $0.left.cursorName = nil
            }
            .written == nil
        )
        #expect(try list("%UX").text == "%UX")
    }
}

/// User commands, the Start menu and the settings commands, driven through the kernel.
@MainActor
@Suite
internal struct ConfigurationCommands {
    internal let box: Sandbox
    internal let settings = MemorySettings()
    internal let plugin: ConfigurationPlugin
    internal let bench: TestBench

    /// The lines the runner started itself (it does not use the command line's job).
    private var shell: (lines: [String], count: Int) { (plugin.launched, plugin.launched.count) }

    internal var commands: CommandRegistry { bench.commands }
    internal var ui: ScriptedInteraction { bench.interaction }
    internal var center: ConfigurationCenter { plugin.center! }

    internal init() throws {
        box = try Sandbox()
        try box.file("A/my file.txt")
        try box.file("A/one.txt")
        try box.file("A/two.txt")
        try box.folder("B")
        plugin = Self.makePlugin(box)
        bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
    }

    internal static func makePlugin(_ box: Sandbox) -> ConfigurationPlugin {
        ConfigurationPlugin(
            launchesApplications: false,
            background: nil,
            listFolder: box.url("lists"),
            settingsKeys: { ["extra.key"] }
        )
    }

    internal func define(
        _ name: String,
        _ command: String,
        _ parameters: String = "",
        startPath: String = "",
        title: String = ""
    ) {
        center.save(
            UserCommand(
                name: name,
                title: title,
                action: CommandAction(command: command, parameters: parameters, startPath: startPath)
            )
        )
    }

    internal var a: String { box.url("A").path }

    // MARK: User commands

    @Test
    internal func aUserCommandRunsAProgramWithExpandedParameters() {
        define("em_show", "echo -n", "%P%N %T")
        #expect(commands[CommandID("em_show")]?.title == "show")
        bench.left.moveCursor(toName: "my file.txt")
        commands.perform("em_show")
        #expect(shell.lines == ["echo -n \"\(a)/my file.txt\" \(box.url("B").path)/"])
        // The start path becomes the folder the line runs in.
        define("em_there", "ls", startPath: "/tmp/some where")
        commands.perform("em_there")
        #expect(shell.lines.last == "cd \"/tmp/some where\" && ls")
        // A change of the definition takes effect at once; a removed command is disabled.
        define("em_show", "open", "%N")
        commands.perform("em_show")
        #expect(shell.lines.last == "open \"my file.txt\"")
        center.removeUserCommand(named: "em_show")
        #expect(!commands.isEnabled("em_show") && commands.perform("em_show") == false && shell.lines.count == 3)
    }

    @Test
    internal func textAfterTheNameReachesTheCommand() {
        bench.left.moveCursor(toName: "one.txt")
        // Parameters field empty: the text is the parameters, placeholders and all.
        define("em_echo", "echo")
        commands.perform("em_echo", .text("hi %N"))
        // Parameters with %A codes take the words; without such a code the text is appended.
        define("em_alias", "tool", "/L=%A1 /R=%A2")
        commands.perform("em_alias", .text("left right"))
        define("em_fixed", "tool", "-v")
        commands.perform("em_fixed", .text("more"))
        // A user command inside another one, with its own text.
        define("em_outer", "em_echo nested %E,em_fixed")
        commands.perform("em_outer")
        #expect(
            shell.lines == ["echo hi one.txt", "tool /L=left /R=right", "tool -v more", "echo nested txt", "tool -v"]
        )
    }

    @Test
    internal func aQuestionMarkLetsTheUserChangeTheParameters() {
        bench.left.moveCursor(toName: "one.txt")
        define("em_ask", "run", "?%N", title: "Ask")
        ui.promptAnswers = [.text("other.txt --flag"), .cancel]
        commands.perform("em_ask")
        commands.perform("em_ask")
        #expect(shell.lines == ["run other.txt --flag"])
        // A name is shown in quotes, so that as typed text it can be nothing but a name.
        #expect(
            ui.log == ["prompt: Parameters for “Ask”: [\"one.txt\"]", "prompt: Parameters for “Ask”: [\"one.txt\"]"]
        )
    }

    @Test
    internal func theListFileExistsWhenTheCommandStarts() {
        define("em_list", "cat", "%L")
        commands.perform(.selectAll)
        commands.perform("em_list")
        let line = shell.lines.first ?? ""
        #expect(line.hasPrefix("cat " + box.url("lists").path + "/list-") && line.hasSuffix(".txt"))
        let written = try? String(contentsOfFile: String(line.dropFirst(4)), encoding: .utf8)
        #expect(written == "\(a)/my file.txt\n\(a)/one.txt\n\(a)/two.txt\n")
    }

    @Test
    internal func commandsOfTheProgramChainsAndCd() {
        // Names in any case; a chain runs in the written order.
        define("em_marks", "CM_selectall,cm_ExchangeSelection,cm_SpreadSelection")
        ui.promptAnswers = [.text("one.*")]
        commands.perform("em_marks")
        #expect(bench.left.model.selection == ["one.txt"])
        // One command takes its parameter from the Parameters field.
        define("em_go", "cd", "%P..")
        define("em_swap", "cd \(box.url("B").path)", startPath: a)
        commands.perform("em_swap")
        #expect(
            bench.left.model.directory.lastPathComponent == "B" && bench.right.model.directory.lastPathComponent == "A"
        )
        // `cd` alone takes the folder from the Parameters field.
        commands.perform("em_go")
        #expect(bench.left.model.directory.path == box.root.path && shell.lines.isEmpty)
        define("em_bad", "cm_DoesNotExist")
        commands.perform("em_bad")
        #expect(ui.log.last == "inform: Unknown command")
    }

    @Test
    internal func aUserCommandThatCallsItselfIsStopped() {
        define("em_a", "em_b")
        define("em_b", "em_a,em_c")
        define("em_c", "echo done")
        commands.perform("em_a")
        // The call back into em_a is refused; the rest of the chain runs.
        #expect(ui.log == ["inform: “a” calls itself"] && shell.lines == ["echo done"])
        define("em_self", "em_self")
        commands.perform("em_self")
        #expect(ui.log.count == 2 && shell.lines.count == 1)
    }

    @Test
    internal func theDefinitionDialogStoresRegistersAndBindsTheKey() {
        ui.formAnswers = [
            .values([
                "name": .text("Backup"), "title": .text("Back Up Now"), "command": .text("rsync -a"),
                "parameters": .text("%P %T"),
                "shortcut": .text("ctrl+shift+b"), "symbol": .text("externaldrive")
            ])
        ]
        commands.perform("afm_NewUserCommand")
        let stored = center.store.userCommands
        #expect(
            stored == [
                UserCommand(
                    name: "em_Backup",
                    title: "Back Up Now",
                    action: CommandAction(command: "rsync -a", parameters: "%P %T"),
                    symbol: "externaldrive"
                )
            ]
        )
        #expect(commands[CommandID("em_Backup")]?.title == "Back Up Now")
        let key = Shortcut(.character("b"), [.control, .shift])
        #expect(bench.kernel.keyBindings.command(for: key) == "em_Backup")
        #expect(
            settings.value([String: [String]].self, forKey: KeyBindings.settingsKey) == ["em_Backup": ["ctrl+shift+b"]]
        )
        #expect(bench.kernel.toolbar.symbol(for: "em_Backup") == "externaldrive")
        commands.perform("em_Backup")
        #expect(shell.lines == ["rsync -a \(a)/ \(box.url("B").path)/"])

        // A name that cannot be used, a name that exists, a key that is taken and kept.
        ui.formAnswers = [
            .values(["name": .text("two words")]), .values(["name": .text("em_Backup")]),
            .values(["name": .text("other"), "command": .text("ls"), "shortcut": .text("⌃⇧B")])
        ]
        for _ in 1...3 { commands.perform("afm_NewUserCommand") }
        #expect(center.store.userCommands.map(\.name) == ["em_Backup", "em_other"])
        #expect(
            bench.kernel.keyBindings.command(for: key) == "em_Backup"
                && ui.log.contains { $0.hasPrefix("choose: ⌃⇧B is already in use") }
        )

        // The next start registers the stored commands with their keys.
        let restarted = TestBench(
            plugins: [NavigationPlugin(), Self.makePlugin(box)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
        #expect(
            restarted.commands[CommandID("em_other")] != nil
                && restarted.kernel.keyBindings.command(for: key) == "em_Backup"
        )
        #expect(restarted.kernel.toolbar.symbol(for: "em_Backup") == "externaldrive")
    }

    // MARK: Start menu

    @Test
    internal func theStartMenuRunsItsEntriesByPosition() throws {
        #expect(commands[CommandID("cm_UserMenu10")] != nil && !commands.isEnabled("cm_UserMenu1"))
        ui.formAnswers = [
            .values([
                "title": .text("List"), "command": .text("ls -l"), "parameters": .text("%N"), "shortcut": .text("f9")
            ])
        ]
        var draft = center.startMenuDraft()
        draft.insert(try #require(center.editStartMenuRow(nil)), after: nil)
        draft.insert(StartMenuDraft.Row(entry: .separator), after: 0)
        draft.insert(
            StartMenuDraft.Row(
                entry: StartMenuEntry(title: "Mark All", action: CommandAction(command: "cm_SelectAll"))
            ),
            after: 1
        )
        center.commit(draft)
        #expect(center.store.startMenu.map(\.title) == ["List", "-", "Mark All"])
        #expect(center.startMenuSections() == [["cm_UserMenu1"], ["cm_UserMenu3"]])
        #expect(center.startMenuDraft() == draft && draft.rows[0].shortcut == "f9")
        #expect(bench.kernel.keyBindings.command(for: .f(9)) == "cm_UserMenu1")

        bench.left.moveCursor(toName: "two.txt")
        commands.perform("cm_UserMenu1")
        commands.perform("cm_UserMenu3")
        #expect(shell.lines == ["ls -l two.txt"] && bench.left.model.selection.count == 3)
        #expect(!commands.isEnabled("cm_UserMenu2") && !commands.isEnabled("cm_UserMenu4"))

        // Reordering moves the key with its entry.
        draft.move(0, by: 1)
        center.commit(draft)
        #expect(
            bench.kernel.keyBindings.command(for: .f(9)) == "cm_UserMenu2"
                && bench.kernel.keyBindings.shortcuts(for: "cm_UserMenu1").isEmpty
        )
        commands.perform("cm_UserMenu2")
        #expect(shell.lines.count == 2)

        // At the next start the entries are in the Start menu, above the editor's entry.
        let restarted = TestBench(
            plugins: [NavigationPlugin(), Self.makePlugin(box)],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
        let start = restarted.kernel.menus.menus.first { $0.title == "Start" }
        #expect(start?.items == ["cm_UserMenu2", "cm_UserMenu3", nil, "cm_ChangeStartMenu", "afm_StopUserCommands"])
        #expect(
            restarted.commands[CommandID("cm_UserMenu2")]?.title == "List"
                && restarted.kernel.keyBindings.command(for: .f(9)) == "cm_UserMenu2"
        )
    }

    // MARK: Registration and settings

    @Test
    internal func theMenusOfTheConfigurationPlugin() {
        let menus = Dictionary(uniqueKeysWithValues: bench.kernel.menus.menus.map { ($0.title, $0.items) })
        #expect(
            menus["Configuration"] == [
                "cm_Config", nil, "cm_Confirmation", "cm_ButtonConfig", "cm_CommandBrowser", "afm_UserCommands",
                "afm_NewUserCommand", nil, "cm_ConfigSavePos", "cm_ConfigSaveSettings", nil,
                "afm_ExportSettings", "afm_ImportSettings", "afm_ResetSettings"
            ]
        )
        #expect(
            menus["Start"] == ["cm_ChangeStartMenu", "afm_StopUserCommands"]
                && menus["Help"] == ["cm_HelpIndex", "cm_Keyboard", "cm_About"]
        )
        #expect(
            bench.kernel.keyBindings.command(for: .cmd(",")) == .configuration
                && bench.kernel.keyClashes.isEmpty
        )
        let all = bench.kernel.menus.menus.flatMap(\.items).compactMap { $0 }
        #expect(all.allSatisfy { commands[$0] != nil })
        #expect(center.keyboardHelp().contains("⌘,") && center.whatIsWhere().contains("English"))
    }

    @Test
    internal func settingsAreExportedImportedAndReset() throws {
        define("em_keep", "ls")
        settings.set(["cm_SelectAll": ["f9"]], forKey: KeyBindings.settingsKey)
        settings.set("value", forKey: "extra.key")
        var changes = 0
        bench.kernel.preferences.add(
            PreferencePage(title: "Demo", preferences: [Preference("demo.flag", "Flag", .flag(default: false))]) {
                changes += 1
            }
        )
        settings.set(true, forKey: "demo.flag")
        #expect(
            center.settingsKeys().contains("demo.flag") && center.settingsKeys().contains("extra.key")
                && center.settingsKeys().contains("configuration.userCommands")
        )

        let file = box.url("settings.json")
        commands.perform("afm_ExportSettings", .location(file))
        #expect(
            try SettingsArchive(data: Data(contentsOf: file)).values.keys.sorted()
                == ["configuration.userCommands", "demo.flag", "extra.key", "keyBindings"]
        )

        // Reset asks first; Cancel changes nothing.
        commands.perform("afm_ResetSettings")
        #expect(settings.flag("demo.flag", default: false) && changes == 0)
        ui.choiceAnswers = [0]
        commands.perform("afm_ResetSettings")
        #expect(
            !settings.flag("demo.flag", default: false) && settings.data(forKey: "extra.key") == nil
                && center.store.userCommands.isEmpty
        )
        #expect(settings.data(forKey: KeyBindings.settingsKey) == nil && changes == 1 && !commands.isEnabled("em_keep"))
        #expect(bench.kernel.keyBindings.command(for: .f(9)) == nil)

        // An import shows what it holds; user commands and key bindings come in only when ticked.
        ui.formAnswers = [.values(["commands": .flag(true), "keys": .flag(true)])]
        commands.perform("afm_ImportSettings", .location(file))
        #expect(
            settings.flag("demo.flag", default: false) && settings.text("extra.key", default: "") == "value"
                && changes == 2
        )
        #expect(center.store.userCommands.map(\.name) == ["em_keep"] && commands.isEnabled("em_keep"))
        // The imported key bindings are in force at once.
        #expect(
            bench.kernel.keyBindings.command(for: .f(9)) == .selectAll
                && ui.log.last == "inform: The settings were imported"
        )

        try "{}".write(to: file, atomically: true, encoding: .utf8)
        commands.perform("afm_ImportSettings", .location(file))
        #expect(ui.log.last == "inform: The settings could not be imported" && center.store.userCommands.count == 1)
    }

    @Test
    internal func theWindowsAreBuiltFromWhatIsRegistered() {
        define("em_mine", "ls", title: "Mine")
        bench.kernel.preferences.add(
            PreferencePage(
                title: "Demo",
                preferences: [
                    Preference("demo.flag", "Flag", .flag(default: false)),
                    Preference("demo.text", "Text", .text(default: "x")),
                    Preference("demo.choice", "Choice", .choice(["a", "b"], default: 0))
                ]
            )
        )
        bench.kernel.preferences.add(PreferencePage(title: "Empty", preferences: []))
        let options = OptionsWindowController(center: center)
        // Pages of the other plugins come first, the dialog's own last.
        #expect(options.pageTitles.contains("Demo") && !options.pageTitles.contains("Empty"))
        #expect(options.pageTitles.suffix(4) == ["Keyboard", "Button Bar", "Start Menu", "Settings File"])
        for (section, title) in [
            (OptionsWindowController.Section.first, options.pageTitles.first ?? ""), (.keyboard, "Keyboard"),
            (.buttonBar, "Button Bar"),
            (.startMenu, "Start Menu"), (.settingsFile, "Settings File")
        ] {
            options.prepare(section)
            options.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(options.shownPage == title)
        }
        let browser = center.browser()
        browser.prepare(picking: false, category: nil)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(
            browser.rows.count == commands.all.count
                && browser.rows.contains { $0.id == "em_mine" && $0.title == "Mine" }
        )
        browser.prepare(picking: true, category: CommandRow.userCategory)
        #expect(browser.rows.map(\.id) == ["em_mine"])
        // A removed user command stays registered until the next start but is no longer offered.
        center.removeUserCommand(named: "em_mine")
        browser.prepare(picking: false, category: nil)
        #expect(!browser.rows.contains { $0.id == "em_mine" })
    }

    @Test
    internal func saveSettingsWritesThePanelsTabs() {
        commands.perform("cm_ConfigSaveSettings")
        let left = settings.value(PanelTabs.State.self, forKey: "left.tabs")
        #expect(left?.tabs.count == 1 && left == bench.left.tabs.state && settings.data(forKey: "right.tabs") != nil)
    }
}
