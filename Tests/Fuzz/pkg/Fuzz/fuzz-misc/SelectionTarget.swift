import AFMKernel
import Foundation
import FuzzCore

@testable import SelectionPlugin

/// The `selection` target: a selection file, loaded into a panel, saved and loaded again.
@MainActor
internal enum SelectionTarget {
    /// The target.
    internal static func make() -> FuzzTarget {
        FuzzTarget(
            "selection",
            maxLen: 4_096,
            dict: ["\r\n", "\n", "\\", "/", "a.txt", "sub\\", "e\u{301}", "é", "\u{2028}", "\u{85}", "C:\\dir\\a.txt"],
            rawDict: [
                [0xFF, 0xFE], [0xFE, 0xFF], [0xEF, 0xBB, 0xBF], [0x00, 0xD8, 0x00, 0xD8], [0x0D, 0x00, 0x0A, 0x00]
            ],
            seeds: seeds,
            run: run
        )
    }

    /// Selection files in each encoding the reader knows, and some it must survive.
    private static func seeds() -> [[UInt8]] {
        var seeds = seedTexts([
            "a.txt\r\nsub\\\r\nb c.txt", "/Users/x/a.txt\n/Users/x/sub/\nC:\\dir\\b c.txt\n",
            "é.txt\ne\u{301}.txt\n\\\\\n//\n"
        ])
        seeds.append([0xFF, 0xFE] + Array("a.txt\r\nsub\\".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        seeds.append([0xFE, 0xFF] + Array("a.txt\r\nsub\\".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        seeds.append([0xEF, 0xBB, 0xBF] + Array("a.txt\n".utf8))
        seeds.append(Array("caf".utf8) + [0xE9, 0x0D, 0x0A, 0x81])
        return seeds
    }

    /// Marks what the file lists in a panel and checks the marks.
    private static func run(_ bytes: [UInt8]) {
        var choices = Choices(bytes)
        // The first line of the input names what the panel shows; the rest is the file.
        let header = choices.until(0x00)
        let data = Data(choices.rest())
        let fileText = SelectionFile.text(from: data)
        let model = panel(header: header, fileText: fileText)
        let names = Set(model.items.map(\.name))
        let listed = SelectionFile.listed(in: fileText, among: names)
        for name in listed {
            fzCheck(names.contains(name), "selection-lists-unknown-name", name.debugDescription)
        }
        fzCheck(SelectionFile.names(in: fileText, among: names) == Set(listed), "selection-names-differ")
        if listed.isEmpty {
            if model.selectionCount != 0 {
                model.clearSelection()
            }
        } else {
            model.setSelection(names: listed)
        }
        fzCheck(model.selectionCount <= model.items.count, "selection-count-too-large")
        let marked = model.items.filter { model.isSelected($0) }
        fzCheck(
            marked.count == model.selectionCount,
            "selection-count-differs",
            "\(marked.count) vs \(model.selectionCount)"
        )
        checkRoundTrip(marked: marked, names: names)
    }

    /// A panel that shows some known names, the names of the header and some names of the file.
    private static func panel(header: [UInt8], fileText: String) -> PanelModel {
        var known = ["a.txt", "sub", "b c.txt", "é.txt", "e\u{301}.txt", "\\", "x\\y", ""]
        known += text(header).split(separator: "\n").prefix(20).map(String.init)
        // Names the file lists are sometimes in the panel.
        let lines = fileText.split(whereSeparator: \.isNewline).map(String.init)
        for (index, line) in lines.prefix(40).enumerated() where index.isMultiple(of: 2) {
            known.append(line)
        }
        let base = fixedURL("mem:///d/")
        var seen = Set<[UInt8]>()
        let unique = known.filter { seen.insert(Array($0.utf8)).inserted }
        let items = unique.enumerated()
            .map { index, name in
                FileItem(url: base.appending(name: name.isEmpty ? "_" : name), name: name, isDirectory: index % 3 == 1)
            }
        let model = PanelModel(directory: base)
        model.show(Listing(directory: base, items: items, parent: nil, root: base))
        return model
    }

    /// Saved and loaded again, the same entries are marked.
    private static func checkRoundTrip(marked: [FileItem], names: Set<String>) {
        for encoding in [SelectionFile.Encoding.unicode, .ansi] {
            let saved = SelectionFile.encode(marked, as: encoding)
            let back = SelectionFile.listed(in: SelectionFile.text(from: saved), among: names)
            guard encoding == .unicode, !names.contains(where: { $0.hasSuffix("\\") }),
                !marked.contains(where: hasAwkwardName)
            else {
                continue
            }
            fzCheck(
                Set(back).isSuperset(of: marked.map(\.name)),
                "selection-roundtrip-loses",
                "\(marked.map(\.name)) -> \(back)"
            )
        }
    }

    /// Whether a name cannot stand on a line of its own in a selection file.
    private static func hasAwkwardName(_ item: FileItem) -> Bool {
        item.name.contains(where: \.isNewline) || item.name.isEmpty || item.name.hasSuffix("\\")
            || item.name.hasSuffix("/")
    }
}
