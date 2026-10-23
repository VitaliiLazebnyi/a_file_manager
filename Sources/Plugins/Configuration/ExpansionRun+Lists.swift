import Foundation

/// The list codes: a file of names the started program reads.
extension ExpansionRun {
    /// Every character that a program may take for the end of a line (Python's `splitlines`
    /// knows these).
    private static func endsALine(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A...0x0D, 0x1C...0x1E, 0x85, 0x2028, 0x2029:
            return true

        default:
            return false
        }
    }

    /// The bytes of the list in `encoding`.
    private static func contents(_ text: String, encoding: ListEncoding) -> Data {
        switch encoding {
        case .plain:
            return Data(text.utf8)

        case .utf8WithMark:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)

        case .utf16WithMark:
            return Data([0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        }
    }

    /// Whether a list code is dropped: nothing is marked, `%y` asks for that, and `%Y` does not
    /// keep a list of the name under the cursor.
    private func dropsList(of panel: PanelSnapshot) -> Bool {
        panel.selection.isEmpty && dropsListWhenUnselected && !(emptyWhenUnselected && panel.cursorName != nil)
    }

    /// A list code puts the name of the list file into the line.
    ///
    /// Only the first list of a command counts.
    internal mutating func list(withPath: Bool, encoding: ListEncoding) {
        guard !listWasRequested else {
            return
        }
        listWasRequested = true
        let panel = first
        guard !dropsList(of: panel) else {
            return
        }
        // Without a path a name that begins with `-` would be an option to whoever reads the list.
        func line(_ name: String, of panel: PanelSnapshot) -> String {
            withPath ? panel.path + name : protected(name)
        }
        var lines = chosen(of: panel).map { line($0, of: panel) }
        if includesTargetSelection { lines += second.selection.map { line($0, of: second) } }
        // The list has one name per line, so a name with a line break in it would be read
        // as two other files. Such a list is not written.
        if let broken = lines.first(where: { $0.unicodeScalars.contains(where: Self.endsALine) }) {
            problem =
                "The name “\(DisplayText.oneLine(broken, limit: 200))” contains a line break "
                + "and cannot be passed in a list file."
        }
        let text = lines.map { $0 + "\n" }.joined()
        let url = context.listFolder.appendingPathComponent("list-\(context.listName).txt")
        listFile = ListFile(url: url, contents: Self.contents(text, encoding: encoding))
        insert(url.path)
    }
}
