import AFMKernel
import Foundation
import FuzzCore
import TestSupport

@testable import FolderTabsPlugin

/// The `tabfile` target: a saved tab file, opened in a panel the way the Folder Tabs plugin does it.
@MainActor
internal enum TabFileTarget {
    /// The target.
    internal static func make() -> FuzzTarget {
        let registry = FileSystemRegistry()
        return FuzzTarget(
            "tabfile",
            maxLen: 4_096,
            dict: [
                "[activetabs]", "[inactivetabs]", "_path=", "_caption=", "_options=", "activetab=", "|", "\n", "=",
                ";", "0", "1", "-1", "9223372036854775807", "-9223372036854775808", "mem:///a", "/Users/x", "~",
                "file:///", "ftp://h/p", "\r\n", "+1_path=/a", "00_path=/b"
            ],
            seeds: seeds,
            setUp: {
                registry.register(MemoryFileSystem())
                registry.register(MemoryFileSystem(scheme: "file"))
            },
            run: { bytes in run(bytes, registry: registry) }
        )
    }

    /// Tab files as the program writes them, and some it must survive.
    private static func seeds() -> [[UInt8]] {
        seedTexts([
            "[activetabs]\n0_path=/Users/x/Projects\n0_caption=Work\n0_options=1|0|0|0|0|1|0\n"
                + "1_path=/Volumes/Backup\n1_options=1|2|1|0|0|0|1\nactivetab=1\n",
            "[activetabs]\n0_path=/a\nactivetab=0\n\n[inactivetabs]\n0_path=mem:///b\n3_path=~/c\n"
                + "3_options=1|4|1\nactivetab=3\n",
            "0_path=/tmp\n", "[inactivetabs]\n5_path=/x\n5_options=|||||1|1\nactivetab=-1\n"
        ])
    }

    /// Reads the file, opens each part of it, and writes it again.
    private static func run(_ bytes: [UInt8], registry: FileSystemRegistry) {
        let base = fixedURL("file:///base/dir/")
        let read = TabFile(text: text(bytes)) { registry.location(from: $0, relativeTo: base) }
        guard let contents = read else {
            return
        }
        let states = [contents.active, contents.inactive].compactMap(\.self)
        for state in states {
            apply(state, replacing: true, base: base)
            apply(state, replacing: false, base: base)
            let direct = PanelTabs(restoring: state, fallback: base)
            _ = direct.active
            _ = direct.state
        }
        // Saved again and read again, the file names the same tabs.
        let written = contents.text { registry.displayPath($0) }
        _ = TabFile(text: written) { registry.location(from: $0, relativeTo: base) }
    }

    /// What FolderTabsPlugin.replace / restore do with the result.
    private static func apply(_ state: PanelTabs.State, replacing: Bool, base: URL) {
        let tabs = PanelTabs(PanelModel(directory: base))
        let old = tabs.tabs
        let opened = open(state, in: tabs)
        let active: Int? = replacing ? min(max(state.active, 0), max(state.tabs.count - 1, 0)) : nil
        let chosen = active.flatMap { opened.indices.contains($0) ? opened[$0] : nil }
        if let chosen, let index = tabs.tabs.firstIndex(where: { $0 === chosen }) {
            tabs.activate(index)
        }
        if replacing, tabs.count > old.count {
            for tab in old {
                tab.isLocked = false
                if let index = tabs.tabs.firstIndex(where: { $0 === tab }) {
                    tabs.closeTab(at: index)
                }
            }
        }
        for index in 0..<tabs.count {
            _ = tabs.title(at: index)
        }
        _ = tabs.active
        let saved = tabs.state
        let restored = PanelTabs(restoring: saved, fallback: base)
        _ = restored.active
        tabs.activateNeighbour(1)
        tabs.activateNeighbour(-1)
    }

    /// Opens the tabs the state names behind the panel's own, and returns them.
    private static func open(_ state: PanelTabs.State, in tabs: PanelTabs) -> [PanelModel] {
        var position = tabs.count
        var opened: [PanelModel] = []
        for record in state.tabs {
            guard let location = URL(string: record.location) else {
                continue
            }
            let tab = tabs.insertTab(showing: location, at: position, activate: false)
            let order = ListOrder(key: SortKey(rawValue: record.sortKey) ?? .name, descending: record.descending)
            if tab.sort != order {
                tab.setSort(order)
            }
            tab.setShowHidden(record.showHidden)
            tab.customTitle = record.title
            tab.isLocked = record.locked ?? false
            opened.append(tab)
            position += 1
        }
        return opened
    }
}
