public import AFMKernel
public import Foundation

/// A saved set of folder tabs (spec 03 › Tab files and storage, 19 › `.tab` files): a text
/// file in INI form, UTF-8, with the tabs of one panel in `[activetabs]` and, when both sides
/// were saved, those of the other panel in `[inactivetabs]`.
///
///     [activetabs]
///     0_path=/Users/x/Projects
///     0_caption=Work
///     0_options=1|0|0|0|0|1|0
///     1_path=/Volumes/Backup
///     1_options=1|2|1|0|0|0|1
///     activetab=1
///
/// `N_path` is the tab's location as the panel writes it (any file system), `N_caption` the
/// name the user gave the tab (left out when there is none), `activetab` the number of the tab
/// that is shown. `N_options` holds fields separated by `|`, in the positions of the original
/// format: 1 (view mode, always 1), the sort key (0 name, 1 extension, 2 size, 3 date,
/// 4 unsorted: this program's numbers), 1 for descending order, two unused fields, 1 for a
/// locked tab, and 1 when hidden files are shown. Missing fields and keys this program does not
/// know are ignored, so a file can be written by hand with nothing but the `N_path` lines.
///
/// A line holds one value, so a path or caption with a line break or another control character
/// in it, or with a space or a quote at its start or end, is written in quotes with backslash
/// escapes (`0_caption="a\nb"`: `\\`, `\"`, `\n`, `\r`, `\t`, `\u{XXXX}`); a value in quotes is
/// read back that way, any other value as it stands (a Windows path with backslashes in it
/// included). At most `tabLimit` tabs are read for a side, paths longer than `pathLimit` and
/// captions longer than `captionLimit` characters are dropped, and a byte-order mark at the
/// start of the file is ignored.
public struct TabFile: Equatable, Sendable {
    public static let tabLimit = 256
    public static let pathLimit = 4_096
    public static let captionLimit = 256

    public var active: PanelTabs.State
    /// The other panel's tabs, when both sides were saved.
    public var inactive: PanelTabs.State?

    public init(active: PanelTabs.State, inactive: PanelTabs.State? = nil) {
        self.active = active
        self.inactive = inactive
    }

    /// The file's text. `displayPath` writes a location the way the user reads it.
    public func text(displayPath: (URL) -> String) -> String {
        func section(_ name: String, _ state: PanelTabs.State) -> String {
            var lines = ["[\(name)]"]
            for (index, tab) in state.tabs.enumerated() {
                let path = URL(string: tab.location).map(displayPath) ?? tab.location
                lines.append("\(index)_path=\(Self.value(path))")
                if let title = tab.title, !title.isEmpty { lines.append("\(index)_caption=\(Self.value(title))") }
                let fields = [
                    1, tab.sortKey, tab.descending ? 1 : 0, 0, 0, tab.locked == true ? 1 : 0, tab.showHidden ? 1 : 0
                ]
                lines.append("\(index)_options=" + fields.map(String.init).joined(separator: "|"))
            }
            lines.append("activetab=\(state.active)")
            return lines.joined(separator: "\n") + "\n"
        }
        return section("activetabs", active) + (inactive.map { "\n" + section("inactivetabs", $0) } ?? "")
    }

    /// A value as it stands on a line: in quotes with escapes when it would not read back the same.
    static func value(_ text: String) -> String {
        let scalars = text.unicodeScalars
        func unsafe(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
        let needsQuotes =
            scalars.first == "\"" || scalars.contains(where: unsafe)
            || scalars.first?.properties.isWhitespace == true || scalars.last?.properties.isWhitespace == true
        guard needsQuotes else { return text }
        var quoted = "\""
        for scalar in scalars {
            switch scalar {
            case "\\": quoted += "\\\\"
            case "\"": quoted += "\\\""
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"

            default:
                if unsafe(scalar) {
                    quoted += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return quoted + "\""
    }

    /// The text a value stands for; a value that is not in quotes, or has an escape that is
    /// not ours, is taken as it is (that is how files written by hand and by other programs read).
    static func unquoted(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count >= 2, scalars.first == "\"", scalars.last == "\"" else { return value }
        var result = String.UnicodeScalarView()
        var index = 1
        while index < scalars.count - 1 {
            let scalar = scalars[index]
            index += 1
            guard scalar == "\\" else {
                if scalar == "\"" { return value }
                result.append(scalar)
                continue
            }
            guard index < scalars.count - 1 else { return value }
            let escape = scalars[index]
            index += 1
            switch escape {
            case "\\", "\"": result.append(escape)
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")

            case "u":
                guard index < scalars.count - 1, scalars[index] == "{",
                    let close = scalars[index...].firstIndex(of: "}"), close < scalars.count - 1
                else { return value }
                let digits = String(String.UnicodeScalarView(scalars[(index + 1)..<close]))
                guard !digits.isEmpty, digits.count <= 6, let number = UInt32(digits, radix: 16),
                    let unicode = Unicode.Scalar(number)
                else { return value }
                result.append(unicode)
                index = close + 1

            default: return value
            }
        }
        return String(result)
    }

    /// The text of a tab file's bytes: UTF-8, with or without a byte-order mark, or UTF-16 with
    /// one (which Windows programs write). Bytes that are none of these are read as UTF-8 as far
    /// as they go.
    public static func text(decoding data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        return String(decoding: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, as: UTF8.self)
    }

    /// Reads a file's text; nil when it names no tab at all. `location` reads a path as the
    /// user would type it; a line it cannot read is skipped.
    public init?(text: String, location: (String) -> URL?) {
        var sections: [String: [String: String]] = [:]
        var current = ""
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = line.dropFirst().dropLast().lowercased()
            } else if let equals = line.firstIndex(of: "="), !line.hasPrefix(";") {
                sections[current, default: [:]][line[..<equals].lowercased()] = String(
                    line[line.index(after: equals)...])
            }
        }

        func state(_ name: String) -> PanelTabs.State? {
            guard let keys = sections[name] else { return nil }
            let numbers = keys.keys.compactMap { key in key.hasSuffix("_path") ? Int(key.dropLast("_path".count)) : nil
            }.sorted()
            var tabs: [PanelTabs.State.Tab] = []
            var active = 0
            let wanted = keys["activetab"].flatMap(Int.init) ?? 0
            for number in numbers {
                guard tabs.count < Self.tabLimit else { break }
                guard let path = keys["\(number)_path"].map(Self.unquoted), path.count <= Self.pathLimit,
                    let url = location(path)
                else { continue }
                let fields = (keys["\(number)_options"] ?? "").split(separator: "|", omittingEmptySubsequences: false)
                    .map { Int($0) ?? 0 }
                func field(_ index: Int) -> Int { fields.indices.contains(index) ? fields[index] : 0 }
                if number == wanted { active = tabs.count }
                tabs.append(
                    PanelTabs.State.Tab(
                        location: url, sortKey: field(1), descending: field(2) == 1, showHidden: field(6) == 1,
                        title: keys["\(number)_caption"].map(Self.unquoted).flatMap {
                            $0.isEmpty || $0.count > Self.captionLimit ? nil : $0
                        },
                        locked: field(5) == 1 ? true : nil))
            }
            return tabs.isEmpty ? nil : PanelTabs.State(tabs: tabs, active: active)
        }

        guard let active = state("activetabs") ?? state("inactivetabs") else { return nil }
        self.active = active
        inactive = sections["activetabs"] == nil ? nil : state("inactivetabs")
    }
}
