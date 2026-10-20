import Foundation

/// What the program is told on the command line: its folders and settings (the argument domain
/// beats its preferences, as in `AppSession`).
internal enum ProgramArguments {
    /// A setting as the program keeps it (JSON), in the property-list form the argument domain
    /// reads: `<hex bytes>` is data.
    internal static func setting(_ value: Any) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return "<" + json.map { String(format: "%02x", $0) }.joined() + ">"
    }

    /// One tab in `folder`, as the program keeps a panel's tabs (`PanelTabs.State`).
    internal static func tabs(at folder: URL) -> [String: Any] {
        let tab: [String: Any] = [
            "location": folder.absoluteString, "sortKey": 0, "descending": false, "showHidden": false
        ]
        return ["tabs": [tab], "active": 0]
    }

    /// The settings every check starts the program with: `left` and `right` in the Full view,
    /// the left panel the source; `extra` adds to them or replaces them.
    internal static func program(left: URL, right: URL, extra: [String: Any]) throws -> [String] {
        let full = ["mode": 0, "extraColumns": [], "columnWidths": [:]] as [String: Any]
        var settings: [String: Any] = [
            "left.tabs": tabs(at: left), "right.tabs": tabs(at: right), "window.sourcePanel": "left",
            "window.divider": 500, "window.panelsStacked": false, "window.fullScreen": false,
            "left.view": full, "right.view": full
        ]
        settings.merge(extra) { _, new in new }
        var arguments = ["-ApplePersistenceIgnoreState", "YES"]
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            arguments += ["-" + key, try setting(value)]
        }
        return arguments
    }

    /// The arguments of the drag check: thumbnails on the left, drops not confirmed.
    internal static func drag(left: URL, right: URL) throws -> [String] {
        let thumbnails = ["mode": 2, "extraColumns": [], "columnWidths": [:]] as [String: Any]
        let extra: [String: Any] = ["left.view": thumbnails, "panel.confirmDragAndDrop": false]
        return try program(left: left, right: right, extra: extra)
    }

    /// The arguments of the Finder Info check: `folder` in both panels, Finder Info on
    /// Ctrl+Opt+Shift+I.
    internal static func finderInfo(folder: URL) throws -> [String] {
        try program(left: folder, right: folder, extra: ["keyBindings": ["afm_FinderInfo": ["ctrl+opt+shift+i"]]])
    }
}
