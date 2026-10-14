import Foundation
import FuzzCore
import TestSupport

@testable import AFMKernel
@testable import ConfigurationPlugin
@testable import FilePropertiesPlugin
@testable import FolderTabsPlugin
@testable import PlacesPlugin
@testable import SelectionPlugin

// Target group 5: descript.ion, tab files, selection files, settings import and the lenient
// decoders of stored settings, parameter expansion, and the shell-quoting property.

func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
func seedTexts(_ s: [String]) -> [[UInt8]] { s.map { Array($0.utf8) } }

// MARK: - descript.ion

/// The first campaign left two known failures out unless FZ_DESCRIPT_ALL was set (a first name that reads
/// like a byte-order mark, a separator joined to its neighbour). Both are fixed, so every check is always on.
let descriptAll = true

/// One well-formed line: a name without separators, a space, a comment.
let descriptLine = FuzzTarget(
    "descript-line", maxLen: 256,
    dict: ["\u{301}", "\u{600}", "\u{200D}", "\u{FE0F}", "é", ".txt", "\u{20D2}", "\u{1F1E6}"],
    seeds: { seedTexts(["\u{8}file.txt\u{0}a comment", "\u{3}a.b\u{0}x"]) },
    run: { bytes in
        var c = Choices(bytes)
        var name = text(c.take(Int(c.byte() % 32)))
        name.unicodeScalars.removeAll { " \"\r\n".unicodeScalars.contains($0) || $0.value == 0xFEFF }
        var comment = text(c.rest())
        comment.unicodeScalars.removeAll { "\r\n".unicodeScalars.contains($0) }
        comment = DescriptIon.normalized(comment)
        guard !name.isEmpty, !comment.isEmpty, !comment.hasSuffix("\u{04}\u{C2}") else { return }
        let quoted = c.bytes.count % 2 == 0
        let line = (quoted ? "\"" + name + "\"" : name) + " " + comment + "\r\n"
        let file = DescriptIon(data: Data([0xEF, 0xBB, 0xBF] + Array(line.utf8)))
        let want = DescriptIon.Entry(name: name, comment: comment)
        fzCheck(
            file.entries.count == 1 && Array(file.entries[0].name.utf8) == Array(name.utf8)
                && Array(file.entries[0].comment.utf8) == Array(comment.utf8),
            quoted ? "descript-quoted-line-misread" : "descript-line-misread",
            "line \(line.debugDescription) wanted \(want) got \(file.entries)")
    })

let descript = FuzzTarget(
    "descript", maxLen: 8_192,
    dict: ["\"", "\r\n", "\n", " ", "\u{04}\u{C2}", "\\n", "descript.ion"],
    rawDict: [
        [0xFF, 0xFE], [0xFE, 0xFF], [0xEF, 0xBB, 0xBF], [0x04, 0xC2], [0x00, 0xD8], [0xD8, 0x00], [0x81], [0x00]
    ],
    seeds: {
        var s = seedTexts([
            "readme.txt A comment\r\n\"my file.txt\" Another one\r\nmulti.txt line one\\nline two\u{04}\u{C2}\r\n",
            "a\r\nb  two spaces\r\n\"unterminated\r\n\"\" empty name\r\n c\r\n",
            "CAFÉ.TXT über\r\ncafé.txt second\r\n"
        ])
        s.append([0xFF, 0xFE] + Array("a b\r\n\"c d\" e\r\n".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        s.append([0xFE, 0xFF] + Array("a b\r\n".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        s.append([0xEF, 0xBB, 0xBF] + Array("x.txt bom\r\n".utf8))
        s.append(Array("name.txt caf".utf8) + [0xE9, 0x81, 0x0D, 0x0A])
        return s
    },
    run: { bytes in
        let data = Data(bytes)
        var file = DescriptIon(data: data)
        let strict = DescriptIon(strict: data)
        if let strict { fzCheck(strict == file, "descript-strict-differs") }
        _ = file.commentsByName
        for entry in file.entries.prefix(50) { _ = file.comment(for: entry.name) }
        // Writing the file again (as any comment change does) must keep every entry.
        let again = DescriptIon(data: file.data())
        // Two known ways the rewrite goes wrong are reported once and then left out here (FZ_DESCRIPT_ALL=1
        // checks them again): a first name that reads like a byte-order mark, and a separator that
        // forms one character with what stands next to it.
        let marks = ["\u{FEFF}", "ÿþ", "þÿ", "ï»¿"]
        let delimiters: Set<Unicode.Scalar> = [" ", "\"", "\r", "\n", "\\"]
        func glued(_ s: String) -> Bool {
            s.contains { $0.unicodeScalars.count > 1 && $0.unicodeScalars.contains(where: delimiters.contains) }
        }
        let known =
            (file.entries.first.map { e in marks.contains { e.name.hasPrefix($0) } } ?? false)
            || file.entries.contains { glued($0.name + " " + $0.comment + "\r\n") || glued("\"" + $0.name + "\" ") }
        if strict != nil, !known || descriptAll {
            fzCheck(
                again.entries == file.entries, "descript-rewrite-changes-entries",
                "before \(file.entries.prefix(5)) after \(again.entries.prefix(5)) bytes \(bytes.prefix(80))")
        }
        // A change of one comment, as the Comment dialog makes it.
        var c = Choices(bytes)
        let name = text(c.take(Int(c.byte() % 16)))
        let comment = text(c.take(Int(c.byte() % 32)))
        file.setComment(comment, for: name.isEmpty ? "new file.txt" : name)
        _ = DescriptIon(data: file.data())
        file.setComment("", for: file.entries.first?.name ?? "x")
        _ = file.data()
        _ = DescriptIon.normalized(comment)
    })

// The store on top of a file system, as the Comment column and the Comment dialog use it.
let descriptStoreFS = MemoryFileSystem()
let descriptStore: FuzzTarget = {
    let registry = FileSystemRegistry()
    return FuzzTarget(
        "descript-store", maxLen: 4_096,
        dict: ["\"", "\r\n", " ", "\u{04}\u{C2}", "\\n"], rawDict: [[0xFF, 0xFE], [0xFE, 0xFF], [0xEF, 0xBB, 0xBF]],
        seeds: { seedTexts(["a.txt hello\r\n\"b c.txt\" world\r\n"]) },
        setUp: { registry.register(descriptStoreFS) },
        run: { bytes in
            descriptStoreFS.removeTree("/d")
            let dir = descriptStoreFS.addDirectory("/d")
            do {
                let w = try descriptStoreFS.write(dir.appending(name: DescriptIon.fileName))
                try w.write(Data(bytes))
                try w.close(attributes: FileAttributes())
            } catch { return }
            let store = CommentStore(fileSystems: registry)
            let comments = store.comments(in: dir)
            _ = store.comment(for: FileItem(url: dir.appending(name: "a.txt"), name: "a.txt", isDirectory: false))
            do {
                try store.setComment("fresh\ncomment", for: "new.txt", in: dir, hidden: false)
                let after = store.comments(in: dir)
                if !descriptAll,
                    comments.keys.contains(where: { k in ["\u{FEFF}", "ÿþ", "þÿ", "ï»¿"].contains { k.hasPrefix($0) } })
                {
                    return
                }
                fzCheck(
                    after["new.txt"] == "fresh\ncomment", "descript-store-set-lost", "\(after["new.txt"] ?? "nil")")
                let marks = ["\u{FEFF}", "ÿþ", "þÿ", "ï»¿"]
                let delimiters: Set<Unicode.Scalar> = [" ", "\"", "\r", "\n", "\\"]
                func glued(_ s: String) -> Bool {
                    s.contains { $0.unicodeScalars.count > 1 && $0.unicodeScalars.contains(where: delimiters.contains) }
                }
                let known = comments.contains { e in
                    marks.contains { e.key.hasPrefix($0) } || glued(e.key + " " + e.value + "\r\n")
                        || glued("\"" + e.key + "\" ")
                }
                if known, !descriptAll { return }
                // A comment that ends with the text of the multi-line marker itself (U+0004 Â) cannot be told from a
                // marked one once it is written: the format has no way to say so. Left out, as in `descript-line`.
                for (name, comment) in comments where name != "new.txt" && !comment.hasSuffix("\u{04}\u{C2}") {
                    fzCheck(
                        after[name] == comment, "descript-store-other-comment-changed",
                        "name \(name.debugDescription) before \(comment.debugDescription) after \((after[name] ?? "nil").debugDescription)"
                    )
                }
            } catch {}
        })
}()

// MARK: - tab files

let tabRegistry = FileSystemRegistry()
let tabFile = FuzzTarget(
    "tabfile", maxLen: 4_096,
    dict: [
        "[activetabs]", "[inactivetabs]", "_path=", "_caption=", "_options=", "activetab=", "|", "\n", "=", ";", "0",
        "1", "-1",
        "9223372036854775807", "-9223372036854775808", "mem:///a", "/Users/x", "~", "file:///", "ftp://h/p", "\r\n",
        "+1_path=/a", "00_path=/b"
    ],
    seeds: {
        seedTexts([
            "[activetabs]\n0_path=/Users/x/Projects\n0_caption=Work\n0_options=1|0|0|0|0|1|0\n1_path=/Volumes/Backup\n1_options=1|2|1|0|0|0|1\nactivetab=1\n",
            "[activetabs]\n0_path=/a\nactivetab=0\n\n[inactivetabs]\n0_path=mem:///b\n3_path=~/c\n3_options=1|4|1\nactivetab=3\n",
            "0_path=/tmp\n", "[inactivetabs]\n5_path=/x\n5_options=|||||1|1\nactivetab=-1\n"
        ])
    },
    setUp: {
        tabRegistry.register(MemoryFileSystem())
        tabRegistry.register(MemoryFileSystem(scheme: "file"))
    },
    run: { bytes in
        let base = URL(string: "file:///base/dir/")!
        guard
            let contents = TabFile(
                text: String(decoding: Data(bytes), as: UTF8.self),
                location: { tabRegistry.location(from: $0, relativeTo: base) })
        else { return }
        // What FolderTabsPlugin.replace / restore do with the result.
        func apply(_ state: PanelTabs.State, replacing: Bool) {
            let tabs = PanelTabs(PanelModel(directory: base))
            let old = tabs.tabs
            var position = tabs.count
            var opened: [PanelModel] = []
            for record in state.tabs {
                guard let location = URL(string: record.location) else { continue }
                let tab = tabs.insertTab(showing: location, at: position, activate: false)
                let order = ListOrder(key: SortKey(rawValue: record.sortKey) ?? .name, descending: record.descending)
                if tab.sort != order { tab.setSort(order) }
                tab.setShowHidden(record.showHidden)
                (tab.customTitle, tab.isLocked) = (record.title, record.locked ?? false)
                opened.append(tab)
                position += 1
            }
            let active: Int? = replacing ? min(max(state.active, 0), max(state.tabs.count - 1, 0)) : nil
            if let active, opened.indices.contains(active),
                let index = tabs.tabs.firstIndex(where: { $0 === opened[active] })
            {
                tabs.activate(index)
            }
            if replacing, tabs.count > old.count {
                for tab in old {
                    tab.isLocked = false
                    if let index = tabs.tabs.firstIndex(where: { $0 === tab }) { tabs.closeTab(at: index) }
                }
            }
            for i in 0..<tabs.count { _ = tabs.title(at: i) }
            _ = tabs.active
            let saved = tabs.state
            let restored = PanelTabs(restoring: saved, fallback: base)
            _ = restored.active
            tabs.activateNeighbour(1)
            tabs.activateNeighbour(-1)
        }
        for state in [contents.active, contents.inactive].compactMap({ $0 }) {
            apply(state, replacing: true)
            apply(state, replacing: false)
            let direct = PanelTabs(restoring: state, fallback: base)
            _ = direct.active
            _ = direct.state
        }
        // Saved again and read again, the file names the same tabs.
        let written = contents.text(displayPath: { tabRegistry.displayPath($0) })
        _ = TabFile(text: written, location: { tabRegistry.location(from: $0, relativeTo: base) })
    })

// MARK: - selection files

let selectionFile = FuzzTarget(
    "selection", maxLen: 4_096,
    dict: ["\r\n", "\n", "\\", "/", "a.txt", "sub\\", "e\u{301}", "é", "\u{2028}", "\u{85}", "C:\\dir\\a.txt"],
    rawDict: [[0xFF, 0xFE], [0xFE, 0xFF], [0xEF, 0xBB, 0xBF], [0x00, 0xD8, 0x00, 0xD8], [0x0D, 0x00, 0x0A, 0x00]],
    seeds: {
        var s = seedTexts([
            "a.txt\r\nsub\\\r\nb c.txt", "/Users/x/a.txt\n/Users/x/sub/\nC:\\dir\\b c.txt\n",
            "é.txt\ne\u{301}.txt\n\\\\\n//\n"
        ])
        s.append([0xFF, 0xFE] + Array("a.txt\r\nsub\\".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        s.append([0xFE, 0xFF] + Array("a.txt\r\nsub\\".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        s.append([0xEF, 0xBB, 0xBF] + Array("a.txt\n".utf8))
        s.append(Array("caf".utf8) + [0xE9, 0x0D, 0x0A, 0x81])
        return s
    },
    run: { bytes in
        var c = Choices(bytes)
        // The first line of the input names what the panel shows; the rest is the file.
        let header = c.until(0x00)
        let data = Data(c.rest())
        let fileText = SelectionFile.text(from: data)
        var known = ["a.txt", "sub", "b c.txt", "é.txt", "e\u{301}.txt", "\\", "x\\y", ""]
        known += text(header).split(separator: "\n").prefix(20).map(String.init)
        // Names the file lists are sometimes in the panel.
        let lines = fileText.split(whereSeparator: \.isNewline).map(String.init)
        for (i, line) in lines.prefix(40).enumerated() where i % 2 == 0 { known.append(line) }
        let base = URL(string: "mem:///d/")!
        var seen = Set<[UInt8]>()
        let items = known.filter { seen.insert(Array($0.utf8)).inserted }.enumerated().map { i, n in
            FileItem(url: base.appending(name: n.isEmpty ? "_" : n), name: n, isDirectory: i % 3 == 1)
        }
        let model = PanelModel(directory: base)
        model.show(Listing(directory: base, items: items, parent: nil, root: base))
        let names = Set(model.items.map(\.name))
        let listed = SelectionFile.listed(in: fileText, among: names)
        for n in listed { fzCheck(names.contains(n), "selection-lists-unknown-name", n.debugDescription) }
        fzCheck(SelectionFile.names(in: fileText, among: names) == Set(listed), "selection-names-differ")
        if listed.isEmpty {
            if model.selectionCount != 0 { model.clearSelection() }
        } else {
            model.setSelection(names: listed)
        }
        fzCheck(model.selectionCount <= model.items.count, "selection-count-too-large")
        let marked = model.items.filter { model.isSelected($0) }
        fzCheck(
            marked.count == model.selectionCount, "selection-count-differs",
            "\(marked.count) vs \(model.selectionCount)")
        // Saved and loaded again, the same entries are marked.
        for encoding in [SelectionFile.Encoding.unicode, .ansi] {
            let saved = SelectionFile.encode(marked, as: encoding)
            let back = SelectionFile.listed(in: SelectionFile.text(from: saved), among: names)
            if encoding == .unicode, !names.contains(where: { $0.hasSuffix("\\") }),
                !marked.contains(where: {
                    $0.name.contains(where: \.isNewline) || $0.name.isEmpty || $0.name.hasSuffix("\\")
                        || $0.name.hasSuffix("/")
                })
            {
                fzCheck(
                    Set(back).isSuperset(of: marked.map(\.name)), "selection-roundtrip-loses",
                    "\(marked.map(\.name)) -> \(back)")
            }
        }
    })

// MARK: - settings import

let settingsSeed = """
    {"format":"A File Manager settings","version":1,"settings":{
    "configuration.userCommands":[{"name":"em_show","title":"Show","action":{"command":"echo -n","parameters":"%P%N %T","startPath":"/tmp"},"symbol":"star"},{"name":"em_b","action":{"command":"cm_wait 5, em_show"}}],
    "configuration.startMenu":[{"title":"One","action":{"command":"ls","parameters":"\\"%S\\""}},{"title":"-"}],
    "configuration.symbols":{"em_show":"star","cm_Exit":"xmark"},
    "keyBindings":{"cm_Exit":["cmd+q","f10","ctrl+opt+shift+cmd+num+"],"em_show":["f5","x"]},
    "left.tabs":{"tabs":[{"location":"file:///tmp/","sortKey":2,"descending":true,"showHidden":false,"title":"T","locked":true},{"location":"mem:///a","sortKey":99,"descending":false,"showHidden":true}],"active":1},
    "right.tabs":{"tabs":[],"active":-5},
    "places.hotlist":{"entries":[{"kind":"item","title":"Home","command":"cd ~","target":"cd /tmp"},{"kind":"submenu","title":"?Sub","children":[{"kind":"separator"},{"title":"x","command":"cm_List 3"}]}],"hideCharacter":"?","hidesMarked":true},
    "places.history.left":{"visits":[{"location":"file:///tmp/","isVisible":true},{"location":"file:///Users/"}]},
    "places.history.frequent":{"counts":{"file:///tmp/":3,"file:///Users/":9}},
    "listingCache.enabled":true,"listingCache.readAhead":false,"extra.key":"plain text"}}
    """

/// What the stored settings are put to after an import (and at the next start): each reader
/// of a known key, driven the way its owner drives it.
func useStoredSettings(_ settings: SettingsStore) {
    let base = URL(string: "file:///base/")!
    KeyBindings().load(from: settings)
    for key in ["left.tabs", "right.tabs"] {
        let state = settings.value(PanelTabs.State.self, forKey: key)
        let tabs = PanelTabs(restoring: state, fallback: base)
        for i in 0..<tabs.count { _ = tabs.title(at: i) }
        _ = tabs.active
        _ = tabs.state
        tabs.activateNeighbour(1)
    }
    let places = settings.scoped(to: "places")
    let tracker = DirectoryHistoryTracker(settings: places)
    for side in DirectoryHistoryTracker.Side.allCases {
        let history = tracker.history(of: side)
        let shown = history.shown(thinning: true, limit: 30) + history.shown(thinning: false)
        let top = tracker.frequent.top(20)
        _ = HistoryMenu(
            history: shown, frequent: top, current: history.current ?? base, displayPath: { $0.absoluteString })
        // The user goes to folders the history names, and elsewhere.
        for url in (shown.prefix(4) + top.prefix(4).map(\.directory) + [base]) { tracker.visited(url, on: side) }
        if let first = shown.first {
            tracker.remove(first, from: side)
            tracker.removeFrequent(first)
        }
    }
    tracker.flush()
    if var hotlist = StoredSettings.load(Hotlist.self, key: "hotlist", in: places, problem: { _ in }) {
        let rows = hotlist.rows
        _ = hotlist.count
        for row in rows.prefix(200) {
            _ = HotlistAction(row.entry.command)
            _ = HotlistAction.targetPath(row.entry.target)
            _ = row.entry.displayTitle
            _ = hotlist.isHidden(row.entry)
            _ = HotlistMenu(hotlist, at: row.path, offersFavorites: true, isCurrent: { $0.command.hasPrefix("cd") })
        }
        _ = HotlistMenu(hotlist, isCurrent: { _ in false })
        if let first = rows.first {
            hotlist.toggleHideMark(at: first.path)
            _ = hotlist.move(at: first.path, by: 1)
            _ = hotlist.remove(at: first.path)
        }
    }
}

final class SettingsBench {
    let settings = MemorySettings()
    let plugin: ConfigurationPlugin
    let bench: TestBench
    let memory = MemoryFileSystem()
    init() {
        let lists = URL(fileURLWithPath: fzWorkDir + "/lists")
        plugin = ConfigurationPlugin(
            launchesApplications: false, background: nil, listFolder: lists,
            settingsKeys: {
                [
                    "extra.key", "places.hotlist", "places.history.left", "places.history.right",
                    "places.history.frequent"
                ]
            })
        memory.addFile("/A/my file.txt")
        memory.addFile("/A/-rf")
        memory.addFile("/A/one.txt")
        _ = memory.addDirectory("/B")
        bench = TestBench(
            plugins: [plugin], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/B"),
            settings: settings)
    }
}

let settingsImport = FuzzTarget(
    "settings", maxLen: 8_192,
    dict: [
        "\"format\"", "\"A File Manager settings\"", "\"settings\"", "\"$data\"", "\"configuration.userCommands\"",
        "\"configuration.startMenu\"",
        "\"configuration.symbols\"", "\"keyBindings\"", "\"left.tabs\"", "\"places.hotlist\"",
        "\"places.history.frequent\"", "\"counts\"", "\"visits\"",
        "\"name\"", "\"action\"", "\"command\"", "\"parameters\"", "\"startPath\"", "\"children\"", "\"kind\"",
        "\"submenu\"", "\"active\"", "\"sortKey\"",
        "9223372036854775807", "-9223372036854775808", "1e400", "null", "true", "[]", "{}", "[[[[[[[[", "\"em_\"", "%S",
        "%N:~1,9223372036854775807",
        "\"%S%E\"", "%|HOME|", "%A-1-", "%B+9", "%C2", "%UL", "cm_wait -5", "cd ", "\\u0000", "\\ud800"
    ],
    // The first seed passes the checks of an import (every part of it is stored when ticked); the second is
    // the same file with a value of a kind the checks refuse, which refuses the whole file.
    seeds: {
        seedTexts([
            settingsSeed, settingsSeed.replacingOccurrences(of: "\"plain text\"", with: "{\"$data\":\"AAEC\"}"),
            "{\"format\":\"A File Manager settings\",\"settings\":{}}",
            "{\"format\":\"A File Manager settings\",\"settings\":{\"configuration.userCommands\":[{\"name\":\"em_x\",\"action\":{\"command\":\"echo\",\"parameters\":\"?%N:~-0,3 %O.%E %B %C1 %L\"}}]}}"
        ])
    },
    run: { bytes in
        let b = SettingsBench()
        guard let center = b.plugin.center else { fzFail("settings-no-center") }
        let url = URL(fileURLWithPath: fzWorkDir + "/import.json")
        try? Data(bytes).write(to: url)
        // An import shows a form and does nothing unless it is answered. Mostly every part is ticked
        // (commands, key bindings, programs, trust, connections, hotlist, tabs), so that all of the file
        // that passes the checks is stored; sometimes it is accepted as proposed, sometimes cancelled.
        let ticked: [String: FormValues.Value] = [
            "commands": .flag(true), "keys": .flag(true), "programs": .flag(true), "trust": .flag(true),
            "connections": .flag(true), "hotlist": .flag(true), "tabs": .flag(true)
        ]
        switch bytes.count % 8 {
        case 0: b.bench.ui.formAnswers = [.accept]
        case 1: b.bench.ui.formAnswers = []
        default: b.bench.ui.formAnswers = [.values(ticked)]
        }
        center.importSettings(from: url)
        // A second import of the same file, everything ticked: nothing may be left half done by the first.
        b.bench.ui.formAnswers = [.values(ticked)]
        center.importSettings(from: url)
        if ProcessInfo.processInfo.environment["FZ_VERBOSE"] != nil {
            do {
                _ = try CheckedSettings(
                    SettingsArchive(data: CheckedSettings.read(url)), schema: center.settingsSchema())
            } catch { print("refused: \(error)") }
            // To see how far an input gets: what the program said, and what was stored.
            print(
                "ui: \(b.bench.ui.log)\nforms shown: \(b.bench.ui.forms.count); user commands \(center.store.userCommands.count), start menu \(center.store.startMenu.count), "
                    + "key bindings stored \(b.settings.data(forKey: KeyBindings.settingsKey) != nil), frequent \(b.settings.data(forKey: "places.history.frequent") != nil)"
            )
        }
        _ = center.commandRows()
        _ = center.startMenuSections()
        _ = center.startMenuDraft()
        // The commands the file brought are run (nothing is launched: the lines are collected).
        b.bench.left.moveCursor(toName: "my file.txt")
        let commands =
            center.store.userCommands.map { ($0.id, $0.action) }
            + center.store.startMenu.enumerated().map { (StartMenuEntry.commandID(at: $0.offset), $0.element.action) }
        for (id, action) in commands.prefix(24) {
            let lowered = action.command.lowercased()
            _ = CommandLanguage.steps(action.command, environment: ["HOME": "/Users/x y"], resolve: { _ in nil })
            // Commands of the program are not performed (some open windows); programs and shell lines are.
            if lowered.contains("cm_") || lowered.contains("em_") || lowered.contains("afm_") || lowered.hasPrefix("cd")
            {
                continue
            }
            b.bench.kernel.commands.perform(id)
        }
        _ = b.plugin.launched
        useStoredSettings(b.settings)
        // Exported again, the file can be read.
        let archive = SettingsArchive.capture(from: b.settings, keys: center.settingsKeys())
        if let out = try? archive.encoded() {
            do { _ = try SettingsArchive(data: out) } catch { fzFail("settings-export-unreadable", "\(error)") }
        }
    })

// MARK: - lenient decoders of stored values

let lenient = FuzzTarget(
    "lenient", maxLen: 8_192,
    dict: [
        "\"name\"", "\"title\"", "\"action\"", "\"command\"", "\"parameters\"", "\"startPath\"", "\"symbol\"",
        "\"children\"", "\"kind\"", "\"item\"",
        "\"submenu\"", "\"separator\"", "\"entries\"", "\"hideCharacter\"", "\"hidesMarked\"", "\"visits\"",
        "\"location\"", "\"isVisible\"", "\"counts\"",
        "\"tabs\"", "\"active\"", "\"sortKey\"", "\"descending\"", "\"showHidden\"", "\"locked\"",
        "9223372036854775807", "-9223372036854775808",
        "1e400", "null", "true", "[]", "{}", "[[[[", "cmd+", "ctrl+", "opt+", "shift+", "f12", "f0", "num+",
        "\"file:///a/\"", "\"\"", "\\ud800", "\\u0000"
    ],
    seeds: {
        seedTexts([
            "[{\"name\":\"em_a\",\"title\":\"A\",\"action\":{\"command\":\"ls\",\"parameters\":\"%S\"},\"symbol\":\"s\"},{\"bad\":1},7]",
            "[{\"title\":\"One\",\"action\":{\"command\":\"ls\"}},{\"title\":\"-\"}]",
            "{\"cm_Exit\":[\"cmd+q\",\"f10\"],\"em_x\":[\"ctrl+opt+shift+cmd+a\",\"num*\",\"f13\"]}",
            "{\"tabs\":[{\"location\":\"file:///tmp/\",\"sortKey\":7,\"descending\":true,\"showHidden\":true,\"title\":\"t\",\"locked\":true}],\"active\":9}",
            "{\"entries\":[{\"kind\":\"submenu\",\"title\":\"?s\",\"children\":[{\"kind\":\"item\",\"title\":\"x\",\"command\":\"cd /a/:\"},5]}],\"hideCharacter\":\"?\",\"hidesMarked\":true}",
            "{\"visits\":[{\"location\":\"file:///a/\",\"isVisible\":true},{\"location\":\"\"},3]}",
            "{\"counts\":{\"file:///a/\":2,\"file:///b/\":9223372036854775807}}", "\"cmd+shift+f5\""
        ])
    },
    run: { bytes in
        let data = Data(bytes)
        _ = try? JSONDecoder().decode(LenientList<UserCommand>.self, from: data)
        _ = try? JSONDecoder().decode(LenientList<StartMenuEntry>.self, from: data)
        if let text = try? JSONDecoder().decode(String.self, from: data) {
            if let shortcut = Shortcut(notation: text) {
                fzCheck(
                    Shortcut(notation: shortcut.notation) == shortcut, "shortcut-notation-roundtrip",
                    "\(text.debugDescription) -> \(shortcut.notation.debugDescription)")
            }
            _ = UserCommand.name(from: text)
        }
        // Each known key holds the input in turn.
        let store = MemorySettings()
        for key in [
            "keyBindings", "left.tabs", "right.tabs", "places.hotlist", "places.history.left", "places.history.right",
            "places.history.frequent",
            "configuration.userCommands", "configuration.startMenu", "configuration.symbols"
        ] { store.set(data as Data?, forKey: key) }
        store.set(data as Data?, forKey: KeyBindings.settingsKey)
        useStoredSettings(store)
        let configuration = ConfigurationStore(settings: store)
        for command in configuration.userCommands.prefix(20) {
            _ = command.caption
            _ = command.id
        }
        _ = configuration.startMenu
        _ = configuration.symbols
    })

// MARK: - parameter expansion

func nameFrom(_ c: inout Choices) -> String {
    let n = Int(c.byte() % 24)
    var s = text(c.take(n))
    s.removeAll { $0 == "/" || $0 == "\0" }
    return s
}

let expansionDict = [
    "%P", "%T", "%N", "%M", "%O", "%E", "%S", "%R", "%B", "%BT", "%B+", "%B-", "%C1", "%C2", "%C9", "%A", "%A-1",
    "%A1-2", "%A2+", "%L", "%F",
    "%D", "%UL", "%WF", "%X", "%x", "%q", "%Q", "%Y", "%y", "%Z", "%a", "%V", "%v", "%%", "%|HOME|", "%|", ":~",
    ":~-0,", ":~1,2", ":~-3,-1~", ",",
    "-", "+", "\"", "'", "\\", "?", " ", "9223372036854775807", "99999999999999999999", "%S+1-", "%S-2-1", "%S3",
    "\"a%Sb%Ec\"", "0", "\n"
]

let pexpand = FuzzTarget(
    "pexpand", maxLen: 2_048, dict: expansionDict,
    seeds: {
        seedTexts([
            "%P%N %T\n", "?\"%S\" '%N' %O.%E\n", "%N:~1,3 %N:~-0,2 %N:~-4 %S+1-2:~0,1\n",
            "\"pre%Smid%Epost\" %P%S %R\n", "%B %B1 %BT2 %B+1 %B+ %C1 %C2 %C3\n",
            "%A %A1 %A-1 %A2-3 %A1+ %q%A%q\n", "%L %F %UL %WF %D %Y%y%a\n", "%X%P%N%x %|HOME| \"%|HOME|\" %Q%N\n",
            "%N:~9223372036854775807,9223372036854775807\n"
        ])
    },
    run: { bytes in
        var c = Choices(bytes)
        let template = text(c.until(0x0A))
        let flags = c.byte()
        var left = PanelSnapshot(
            path: "/Users/x y/Docs/", cursorName: "my file.tar.gz", selection: ["a.txt", "b c.txt", "-rf", "é.d"])
        var right = PanelSnapshot(path: "/Volumes/Back up/", cursorName: "other.bin", selection: ["z"])
        if flags & 1 != 0 { left.cursorName = flags & 2 != 0 ? nil : nameFrom(&c) }
        if flags & 4 != 0 { left.selection = (0..<Int(c.byte() % 5)).map { _ in nameFrom(&c) } }
        if flags & 8 != 0 { left.path = flags & 16 != 0 ? "" : "/" + nameFrom(&c) + "/" }
        if flags & 32 != 0 {
            right = PanelSnapshot(path: nameFrom(&c), cursorName: flags & 64 != 0 ? nil : nameFrom(&c), selection: [])
        }
        let arguments = flags & 128 != 0 ? text(c.take(Int(c.byte() % 40))) : "one \"two three\" four"
        let context = ExpansionContext(
            left: left, right: right, sourceIsRight: flags & 2 != 0, environment: ["HOME": "/Users/x y", "E": "a\"b"],
            arguments: arguments, listFolder: URL(fileURLWithPath: "/tmp/lists"), listName: "fixed")
        let result = ParameterExpander(context: context).expand(template)
        fzCheck(ParameterExpander(context: context).expand(template) == result, "pexpand-unstable")
        // The words around it: what the runner and the command language do with such text.
        _ = ShellWords.split(result.text)
        _ = ShellWords.split(template, at: ",")
        _ = ShellWords.unquoted(template)
        _ = ShellWords.quoted(template)
        _ = CommandLanguage.expandingEnvironment(template, context.environment)
        let steps = CommandLanguage.steps(
            template, environment: context.environment,
            resolve: { $0.lowercased().hasPrefix("cm_") ? CommandID(rawValue: $0) : nil })
        for step in steps {
            if case .perform(_, let parameter) = step {
                _ = CommandLanguage.argument(from: parameter, location: { URL(fileURLWithPath: $0) })
            }
        }
        _ = CommandLanguage.argument(from: template, location: { URL(fileURLWithPath: $0) })
        _ = UserCommand.name(from: template)
        _ = CommandRunner.applicationLine(for: result.text)
        // What a shell would be given, and what the user is shown and may edit.
        fzCheck(ShellLine.display(result.pieces) == result.text, "pexpand-text-is-not-the-display")
        switch ShellLine.script(result.pieces) {
        case .failure(let refusal): _ = refusal.explanation

        case .success(let script):
            // The values are apart from the line: as many references as values, each of the harmless form.
            // (By bytes: a reference may be followed by a combining mark of the user's text, which joins its brace.)
            let line = Data(script.line.utf8)
            for index in script.values.indices {
                fzCheck(
                    line.range(of: Data(("${" + ShellLine.variable(index) + "}").utf8)) != nil,
                    "pexpand-script-value-without-reference", script.line.debugDescription)
            }
            _ = script.text
            _ = script.arguments
        }
        let prompt = ShellLine.prompt(result.pieces)
        _ = ShellLine.script(ShellLine.pieces(fromPrompt: prompt.text, values: prompt.values))
        _ = ShellLine.pieces(fromPrompt: template, values: prompt.values)
        _ = ParameterExpander.usesSelection(result.pieces)
        if let pieces = CommandRunner.applicationLine(for: result.pieces) { _ = ShellLine.script(pieces) }
        _ = CommandLanguage.environmentPieces(template, context.environment)
    })

// MARK: - names and values against real shells
//
// The contract since review 2: what a placeholder stands for is data. The shell is given the
// user's line with a reference in place of every value (`ShellLine.script`) and the values as
// its arguments, started the way the program starts it (`ChildProcess.spawn`, arguments byte
// for byte). So for every name, in every place a placeholder may stand:
//   1. nothing of the name runs (no file appears in the folder the line ran in, and the output
//      holds exactly the expected arguments);
//   2. the program receives the name byte for byte (only a name that begins with `-` and is a
//      word of its own arrives as `./-name`, the same file);
//   3. the text the shell reads does not depend on the names at all;
//   4. in a place where no reference is safe the line is refused, never run.

let quotePieces: [String] = [
    " ", "\t", "\n", "\r", "\"", "'", "\\", "$", "`", "!", "*", "?", "[", "]", "(", ")", "{", "}", "<", ">", "|", "&",
    ";", "~", "#", "=",
    "-", "%", "^", ",", ":", "@", "+", ".", "a", "b", "x", "$(id)", "`id`", "${HOME}", "$HOME", "\u{301}", "\u{200D}",
    "\u{FE0F}",
    "\u{1F600}", "é", "\u{A0}", "\u{2028}", "\u{85}", "\u{1}", "\u{7F}", "\u{1B}", "\u{8}", "\\n", "--", "-n", "-e",
    "'\\''", "\"\"",
    "\u{20D2}", "\u{0338}", ".txt", "a.", "..", "\u{FEFF}", "\u{3000}", "$0", "$1", "~root", "=ls", "{a,b}", "*.*",
    "\u{0}",
    // Each of these makes a file named M… in the folder of the run if a shell ever reads it as code.
    "$(touch M1)", "`touch M2`", ";touch M3;", "\ntouch M4\n", "|touch M5", "&&touch M6", ">M7", "$(touch M8)\u{301}",
    "\"\u{301};touch M9;\"\u{301}",
    "';touch M10;'", "\";touch M11;\"", "\\\u{301}", "$\u{301}(touch M12)", "${IFS}touch${IFS}M13", "%Q", "%N", "%|V|",
    "${__afm_1}", "\"${1}\"",
    "e\u{301}", "\u{1100}\u{1161}", "\u{212B}"
]

func hostileName(_ c: inout Choices) -> String {
    var s = ""
    let count = 1 + Int(c.byte() % 6)
    for _ in 0..<count {
        let b = c.byte()
        if b < 0xC0 {
            s += quotePieces[Int(b) % quotePieces.count]
        } else if b < 0xE0 {
            s.unicodeScalars.append(Unicode.Scalar(UInt8(max(1, c.byte()))))
        }  // every byte value 0x01–0xFF as a character
        else if let scalar = Unicode.Scalar(c.u32() % 0x11_0000), scalar.value != 0 {
            s.unicodeScalars.append(scalar)
        }
    }
    s.unicodeScalars.removeAll { $0 == "/" || $0.value == 0 }
    return s.isEmpty ? "a" : s
}

/// Marks the end of one case's arguments in the output. No generated name holds it.
let quoteSeparator = "@@SEP-7f3a@@"

/// What a shell made of a line, and what the line left behind.
struct ShellOutcome {
    /// The bytes of each argument, per case.
    var cases: [[[UInt8]]]
    /// Files that appeared in the folder the line ran in.
    var created: [String]
}

var shellRuns = 0

/// Runs the cases in one script, exactly as the program hands a line to a shell: `ShellLine.script`
/// for the text and the values, `ChildProcess.spawn` for the start. Each case is the pieces that
/// follow `printf '%s\0' ` (or, with `external`, `/usr/bin/printf '%s\0' `: a program of its own,
/// so that what a started program receives is checked too). Nil when the line was refused.
func runThroughShell(_ shell: String, _ cases: [(pieces: [ExpandedPiece], external: Bool)]) -> Result<
    ShellOutcome, ShellContext.Refusal
> {
    var pieces: [ExpandedPiece] = [.text("exec >.out 2>/dev/null\n")]
    for one in cases {
        pieces +=
            [.text((one.external ? "/usr/bin/printf" : "printf") + " '%s\\0' ")] + one.pieces + [
                .text("\nprintf '%s\\0' \(quoteSeparator)\n")
            ]
    }
    let script: ShellScript
    switch ShellLine.script(pieces) {
    case .failure(let refusal): return .failure(refusal)
    case .success(let made): script = made
    }
    shellRuns += 1
    let folder = fzWorkDir + "/shell-\(shellRuns % 4)"
    try? FileManager.default.removeItem(atPath: folder)
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    // The shell's own start files are left out (`-f`, no login): they belong to whoever runs this.
    let options = shell.hasSuffix("zsh") ? ["-f", "-c"] : ["-c"]
    let environment = ["PATH": "/usr/bin:/bin", "HOME": folder, "LC_ALL": "en_US.UTF-8"]
    guard
        case .success(let pid) = ChildProcess.spawn(
            executable: shell, arguments: options + script.arguments, environment: environment, directory: folder)
    else {
        fzFail("quote-shell-not-started", shell)
    }
    var status: Int32 = 0
    var result: pid_t
    repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
    let output = FileManager.default.contents(atPath: folder + "/.out").map { [UInt8]($0) } ?? []
    var arguments = output.split(separator: 0, omittingEmptySubsequences: false).map(Array.init)
    if arguments.last == [] { arguments.removeLast() }
    var groups = arguments.split(separator: Array(quoteSeparator.utf8), omittingEmptySubsequences: false).map(
        Array.init)
    if groups.last == [] { groups.removeLast() }
    let created = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0 != ".out" }
        .sorted()
    return .success(ShellOutcome(cases: groups, created: created))
}

struct QuoteCase {
    let template: String
    let pieces: [ExpandedPiece]
    /// The same template expanded with tame names of the same number: its line must be the same.
    let tamePieces: [ExpandedPiece]
    /// Per argument, the acceptable values.
    let expected: [[String]]
    let detail: String
}

/// A name that begins with `-` and is a word of its own arrives as `./-name`: the same file.
func guarded(_ name: String) -> String { name.unicodeScalars.first == "-" ? "./" + name : name }

/// Places where no reference to a value can be written safely: the line must be refused.
let refusedTemplates = [
    "`printf %s %N`", "\"`echo %N`\"", "$'%N'", "echo # %N", "cat <<EOF\n%N\nEOF", "\\%N", "$((%N + 1))", "((x = %N))",
    "echo $[%N]",
    "${x:-%N}", "$%N", "echo \"\\%N\"", "[[ %N -eq 1 ]]", "[ 1 -lt %N ]", "echo $arr[%N]"
]

func describeBytes(_ groups: [[UInt8]]) -> String {
    groups.map { String(decoding: $0, as: UTF8.self).debugDescription + " \($0)" }.joined(separator: ", ")
}

/// Checks one set of cases in both shells.
func checkQuoteCases(_ cases: [QuoteCase]) {
    for one in cases where !quoteControlIsOn {
        // 3. The text for the shell is the same whatever the names are.
        guard case .success(let script) = ShellLine.script(one.pieces) else {
            fzFail("quote-refused " + one.template, one.detail)
        }
        guard case .success(let tame) = ShellLine.script(one.tamePieces) else {
            fzFail("quote-refused-tame " + one.template, one.detail)
        }
        fzCheck(
            script.line == tame.line && script.values.count == tame.values.count,
            "quote-line-depends-on-the-names " + one.template,
            "\(one.detail)\nline: \(script.line.debugDescription)\nwith tame names: \(tame.line.debugDescription)")
    }
    for shell in ["/bin/zsh", "/bin/sh"] {
        // The first case of every set goes to a program of its own.
        let run = cases.enumerated().map {
            (pieces: $0.element.pieces, external: $0.element.template == "%N" && $0.offset < 200)
        }
        guard case .success(let outcome) = runThroughShell(shell, run) else {
            fzFail("quote-refused-in-script", shell)
        }
        // 1. Nothing of a name ran.
        fzCheck(
            outcome.created.isEmpty, "quote-command-ran " + shell,
            "created \(outcome.created)\n" + cases.prefix(40).map(\.detail).joined(separator: "\n"))
        fzCheck(
            outcome.cases.count == cases.count, "quote-script-broken " + shell,
            "\(outcome.cases.count) cases came back of \(cases.count)\n"
                + cases.prefix(40).map(\.detail).joined(separator: "\n"))
        // 2. The arguments are the names, byte for byte.
        for (one, got) in zip(cases, outcome.cases) {
            let fits =
                got.count == one.expected.count
                && zip(one.expected, got).allSatisfy { accepted, bytes in accepted.contains { Array($0.utf8) == bytes }
                }
            if !fits {
                fzFail(
                    "quote-argument-differs \(one.template) \(shell)",
                    "\(one.detail)\nexpected: \(one.expected.map { $0.map { $0.debugDescription + " \(Array($0.utf8))" } })\ngot: \(describeBytes(got))"
                )
            }
        }
    }
}

/// Positive control (FZ_QUOTE_CONTROL=1): the values are pasted into the line as text, the way a
/// program without the protection would do it. The checks must then fail for a hostile name;
/// if they pass, the oracle is blind.
let quoteControlIsOn = ProcessInfo.processInfo.environment["FZ_QUOTE_CONTROL"] != nil
func quoteControl(_ pieces: [ExpandedPiece]) -> [ExpandedPiece] {
    guard quoteControlIsOn else { return pieces }
    return pieces.map { piece in
        guard case .value(let value) = piece else { return piece }
        return .text(value)
    }
}

/// The cases of one set of names.
func quoteCases(name: String, dir: String, value: String, selection: [String]) -> [QuoteCase] {
    let path = "/tmp/" + dir + "/"
    func expander(_ name: String, _ path: String, _ value: String, _ selection: [String]) -> ParameterExpander {
        ParameterExpander(
            context: ExpansionContext(
                left: PanelSnapshot(path: path, cursorName: name, selection: selection),
                right: PanelSnapshot(path: "/other/", cursorName: "o", selection: []),
                environment: ["V": value], listFolder: URL(fileURLWithPath: fzWorkDir + "/lists"), listName: "fixed"))
    }
    let real = expander(name, path, value, selection)
    let tame = expander("n", "/tmp/d/", "v", selection.map { _ in "s" })
    let inputs =
        "name=\(name.debugDescription) dir=\(dir.debugDescription) value=\(value.debugDescription) selection=\(selection.map(\.debugDescription))"
    var cases: [QuoteCase] = []
    func add(_ template: String, _ expected: [[String]]) {
        let expanded = real.expand(template)
        fzCheck(
            expanded.problem == nil && !expanded.missingName, "quote-expansion-problem " + template,
            inputs + " problem \(expanded.problem ?? "missing name")")
        cases.append(
            QuoteCase(
                template: template, pieces: quoteControl(expanded.pieces), tamePieces: tame.expand(template).pieces,
                expected: expected, detail: "template \(template.debugDescription) " + inputs))
    }
    add("%N", [[guarded(name)]])
    add("\"%N\"", [[guarded(name)]])
    add("'%N'", [[guarded(name)]])
    add("%P%N", [[path + name]])
    add("\"%P%N\"", [[path + name]])
    add("'%P%N'", [[path + name]])
    add("x%N", [["x" + name]])
    add("--out=%N", [["--out=" + name]])
    add("%N.bak", [[guarded(name) + ".bak"]])
    add("\"pre %N post\"", [["pre " + name + " post"]])
    add("'pre %N post'", [["pre " + name + " post"]])
    add("\"pre%Npost\"", [["pre" + name + "post"]])
    add("'pre%Npost'", [["pre" + name + "post"]])
    add("-o %N", [["-o"], [guarded(name)]])
    add("\"$(printf '%%s' x)\" %N", [["x"], [guarded(name)]])
    add("%S", selection.map { [guarded($0)] })
    add("%P%S", selection.map { [path + $0] })
    add("\"%S\"", selection.map { [guarded($0)] })
    add("\"new-%S-old\"", selection.map { ["new-" + $0 + "-old"] })
    add("\"%P%S\"", selection.map { [path + $0] })
    // The value of a variable is data like a name; it is no file name, so nothing is put before a `-`,
    // but a guard there would do no harm either.
    add("%|V|", [[value, guarded(value)]])
    add("\"%|V|\"", [[value, guarded(value)]])
    add("'%|V|'", [[value, guarded(value)]])
    add("%T%N", [["/other/" + name]])
    // The Command field, where %NAME% is an environment variable.
    for template in ["%V%", "\"%V%\"", "'%V%'", "x=%V%"] {
        let before = template.hasPrefix("x=") ? "x=" : ""
        cases.append(
            QuoteCase(
                template: "command-field " + template,
                pieces: CommandLanguage.environmentPieces(template, ["V": value]),
                tamePieces: CommandLanguage.environmentPieces(template, ["V": "v"]),
                expected: [[before + value] + (before.isEmpty ? [guarded(value)] : [])],
                detail: "command field \(template.debugDescription) value=\(value.debugDescription)"))
    }
    // 4. Where no reference is safe, the line is refused whatever the name.
    for template in refusedTemplates {
        if case .success(let script) = ShellLine.script(real.expand("printf %s " + template).pieces) {
            fzFail("quote-unsafe-place-not-refused " + template, inputs + "\nline: \(script.line.debugDescription)")
        }
    }
    return cases
}

var quoteCasesRun = 0

let quote = FuzzTarget(
    "quote", maxLen: 1_024,
    seeds: {
        [
            [1, 0, 1, 4, 1, 5, 1, 7, 1, 8, 2, 4, 41, 2, 26, 34],
            [3, 34, 0, 34, 2, 5, 0, 37, 2, 4, 37, 1, 61, 2, 34, 41],
            [2, 0xC1, 0x41, 0xC1, 0x80, 1, 0xC1, 0xFF, 1, 3, 2, 26, 26],
            Array(repeating: 4, count: 20), Array(repeating: 41, count: 20), Array(0..<64), Array(64..<128),
            Array((128..<192).map { UInt8($0) }),
            Array((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }),
            Array((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 101 &+ 3) })
        ]
    },
    run: { bytes in
        var c = Choices(bytes)
        var cases: [QuoteCase] = []
        var sets = 0
        // Several sets of names per shell launch: launching is what takes the time.
        while sets < 12, sets == 0 || !c.atEnd {
            sets += 1
            let name = hostileName(&c)
            let dir = hostileName(&c)
            let value = hostileName(&c)
            cases += quoteCases(
                name: name, dir: dir, value: value, selection: [hostileName(&c), hostileName(&c), hostileName(&c)])
        }
        checkQuoteCases(cases)
        quoteCasesRun += cases.count * 2
        fzNote("quote cases checked by this worker: \(quoteCasesRun)")
    })

/// One name, given as the input's UTF-8 text, as the cursor name, a marked name, a folder and the
/// value of a variable, through every template of `quote` in zsh and sh. Prints what arrived.
let quoteDemo = FuzzTarget(
    "quote-demo", maxLen: 256, seeds: { seedTexts(["my file.txt"]) },
    run: { bytes in
        var name = text(bytes)
        name.unicodeScalars.removeAll { $0 == "/" || $0.value == 0 }
        guard !name.isEmpty else { return }
        let cases = quoteCases(name: name, dir: name, value: name, selection: [name, "b c", name])
        for shell in ["/bin/zsh", "/bin/sh"] {
            if case .success(let outcome) = runThroughShell(
                shell, cases.prefix(3).map { (pieces: $0.pieces, external: true) })
            {
                print(
                    "\(shell) %N, \"%N\", '%N' to /usr/bin/printf: \(outcome.cases.map(describeBytes)); files created: \(outcome.created)"
                )
            }
        }
        checkQuoteCases(cases)
    })

fuzzMain([
    quoteDemo, descript, descriptLine, descriptStore, tabFile, selectionFile, settingsImport, lenient, pexpand, quote
])
