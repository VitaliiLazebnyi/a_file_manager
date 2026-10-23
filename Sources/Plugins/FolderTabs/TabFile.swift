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
    /// The most tabs read for one side.
    public static let tabLimit = 256
    /// The longest path read, in characters; a longer one is dropped with its tab.
    public static let pathLimit = 4_096
    /// The longest caption read, in characters; a longer one is dropped, the tab stays.
    public static let captionLimit = 256

    /// The tabs of the panel the file was saved from, or the only side it holds.
    public var active: PanelTabs.State
    /// The other panel's tabs, when both sides were saved.
    public var inactive: PanelTabs.State?

    /// A tab file of one side, or of both.
    public init(active: PanelTabs.State, inactive: PanelTabs.State? = nil) {
        self.active = active
        self.inactive = inactive
    }

    /// Reads a file's text; nil when it names no tab at all.
    ///
    /// `location` reads a path as the user would type it; a line it cannot read is skipped.
    public init?(text: String, location: (String) -> URL?) {
        let sections = Self.sections(of: text)
        func state(_ name: String) -> PanelTabs.State? {
            sections[name].flatMap { keys in Self.state(of: keys, location: location) }
        }
        guard let first = state("activetabs") ?? state("inactivetabs") else {
            return nil
        }
        active = first
        inactive = sections["activetabs"] == nil ? nil : state("inactivetabs")
    }

    /// The keys of each section of an INI text, both in lower case; a byte-order mark at the
    /// start and lines starting with `;` are ignored.
    private static func sections(of text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current = ""
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for rawLine in body.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = line.dropFirst().dropLast().lowercased()
            } else if let equals = line.firstIndex(of: "="), !line.hasPrefix(";") {
                sections[current, default: [:]][line[..<equals].lowercased()] = String(
                    line[line.index(after: equals)...]
                )
            }
        }
        return sections
    }

    /// The tabs of one section, in the order of their numbers; nil when none can be read.
    private static func state(of keys: [String: String], location: (String) -> URL?) -> PanelTabs.State? {
        let numbers = keys.keys
            .compactMap { key in key.hasSuffix("_path") ? Int(key.dropLast("_path".count)) : nil }
            .sorted()
        var tabs: [PanelTabState] = []
        var shown = 0
        let wanted = keys["activetab"].flatMap(Int.init) ?? 0
        for number in numbers {
            guard tabs.count < tabLimit else { break }
            guard let path = keys["\(number)_path"].map(unquoted), path.count <= pathLimit,
                let url = location(path)
            else { continue }
            if number == wanted { shown = tabs.count }
            tabs.append(tab(number, at: url, keys: keys))
        }
        return tabs.isEmpty ? nil : PanelTabs.State(tabs: tabs, active: shown)
    }

    /// The tab numbered `number` of a section, showing `url`, with its caption and options.
    private static func tab(_ number: Int, at url: URL, keys: [String: String]) -> PanelTabState {
        let fields = (keys["\(number)_options"] ?? "")
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        func field(_ index: Int) -> Int { fields.indices.contains(index) ? fields[index] : 0 }
        var tab = PanelTabState(
            location: url,
            showHidden: field(6) == 1,
            title: keys["\(number)_caption"]
                .map(unquoted)
                .flatMap { caption in caption.isEmpty || caption.count > captionLimit ? nil : caption },
            locked: field(5) == 1
        )
        // The sort key as the file has it, known or not.
        (tab.sortKey, tab.descending) = (field(1), field(2) == 1)
        return tab
    }

    /// A value as it stands on a line: in quotes with escapes when it would not read back the same.
    internal static func value(_ text: String) -> String {
        let scalars = text.unicodeScalars
        func unsafe(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                return true

            default:
                return false
            }
        }
        let needsQuotes =
            scalars.first == "\"" || scalars.contains(where: unsafe)
            || scalars.first?.properties.isWhitespace == true || scalars.last?.properties.isWhitespace == true
        guard needsQuotes else {
            return text
        }
        var quoted = "\""
        for scalar in scalars {
            switch scalar {
            case "\\":
                quoted += "\\\\"

            case "\"":
                quoted += "\\\""

            case "\n":
                quoted += "\\n"

            case "\r":
                quoted += "\\r"

            case "\t":
                quoted += "\\t"

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
    internal static func unquoted(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count >= 2, scalars.first == "\"", scalars.last == "\"" else {
            return value
        }
        var result = String.UnicodeScalarView()
        var index = 1
        while index < scalars.count - 1 {
            let scalar = scalars[index]
            index += 1
            if scalar == "\"" {
                return value
            }
            guard scalar == "\\" else {
                result.append(scalar)
                continue
            }
            guard let escaped = escape(in: scalars, at: &index) else {
                return value
            }
            result.append(escaped)
        }
        return String(result)
    }

    /// The character the escape at `index` (just after its backslash) of a quoted value stands
    /// for; `index` moves past the escape.
    ///
    /// Nil for an escape that is not ours, or one the closing quote cuts off.
    private static func escape(in scalars: [Unicode.Scalar], at index: inout Int) -> Unicode.Scalar? {
        // The last scalar is the closing quote.
        let end = scalars.count - 1
        guard index < end else {
            return nil
        }
        let escape = scalars[index]
        index += 1
        switch escape {
        case "\\", "\"":
            return escape

        case "n":
            return "\n"

        case "r":
            return "\r"

        case "t":
            return "\t"

        case "u":
            guard index < end, scalars[index] == "{", let close = scalars[index...].firstIndex(of: "}"), close < end
            else { return nil }
            let digits = String(String.UnicodeScalarView(scalars[(index + 1)..<close]))
            guard !digits.isEmpty, digits.count <= 6, let number = UInt32(digits, radix: 16),
                let unicode = Unicode.Scalar(number)
            else { return nil }
            index = close + 1
            return unicode

        default:
            return nil
        }
    }

    /// The text of a tab file's bytes: UTF-8, with or without a byte-order mark, or UTF-16 with
    /// one (which Windows programs write).
    ///
    /// Bytes that are none of these are read as UTF-8 as far as they go.
    public static func text(decoding data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) {
                return text
            }
        }
        return repairedUTF8(data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data)
    }

    /// The text of UTF-8 bytes; every sequence that is not valid UTF-8 becomes U+FFFD, as
    /// `String(decoding:as:)` does, where the failable `String(bytes:encoding:)` gives nothing.
    private static func repairedUTF8(_ bytes: Data) -> String {
        var scalars = String.UnicodeScalarView()
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        decoding: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                scalars.append(scalar)

            case .emptyInput:
                break decoding

            case .error:
                scalars.append("\u{FFFD}")
            }
        }
        return String(scalars)
    }

    /// The file's text.
    ///
    /// `displayPath` writes a location the way the user reads it.
    public func text(displayPath: (URL) -> String) -> String {
        func section(_ name: String, _ state: PanelTabs.State) -> String {
            var lines = ["[\(name)]"]
            for (index, tab) in state.tabs.enumerated() {
                let path = URL(string: tab.location).map(displayPath) ?? tab.location
                lines.append("\(index)_path=\(Self.value(path))")
                if let title = tab.title, !title.isEmpty { lines.append("\(index)_caption=\(Self.value(title))") }
                let fields = [
                    1, tab.sortKey, tab.descending ? 1 : 0, 0, 0, tab.locked ? 1 : 0, tab.showHidden ? 1 : 0
                ]
                lines.append("\(index)_options=" + fields.map(String.init).joined(separator: "|"))
            }
            lines.append("activetab=\(state.active)")
            return lines.joined(separator: "\n") + "\n"
        }
        return section("activetabs", active) + (inactive.map { other in "\n" + section("inactivetabs", other) } ?? "")
    }
}
