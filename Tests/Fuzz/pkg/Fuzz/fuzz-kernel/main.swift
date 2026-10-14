import Foundation
import FuzzCore

@testable import AFMKernel

/// Text from fuzz bytes: mostly UTF-8 as it comes (invalid sequences are repaired by the decoder).
func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

var slowestMask = 0.0

let fileMask = FuzzTarget(
    "filemask", maxLen: 4_096,
    dict: [
        "*", "?", "[", "]", "*.*", "*.", ".", ";", " ", "[!a-z]", "[[:alpha:]]", "\\", "*a*a*a*a*a*a*a*a*b",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "É", "ß", "İ", "\u{0}"
    ],
    seeds: {
        [
            "*.txt *.md\nreadme.txt", "report_??.*\nreport_01.pdf", "*a*\nbanana", "*.\nREADME", "[a-c]*;*.JPG\nb.jpg",
            "*é*\nCAFÉ.TXT", "name.\nname", "*a*a*a*a*a*b\naaaaaaaaaaaaaaaaaaaaaaaa"
        ].map { Array($0.utf8) }
    },
    run: { bytes in
        var c = Choices(bytes)
        let pattern = text(c.until(0x0A))
        let name = text(c.rest())
        let t = Date()
        let mask = FileMask(pattern)
        let a = mask.matches(name)
        let dt = Date().timeIntervalSince(t)
        if dt > slowestMask {
            slowestMask = dt
            fzNote(
                "filemask slowest \(Int(dt * 1e6)) us pattern=\(pattern.debugDescription.prefix(200)) name=\(name.debugDescription.prefix(200))"
            )
        }
        // Matching is a function of its arguments, and `*` takes everything.
        fzCheck(mask.matches(name) == a, "filemask-unstable", "\(pattern.debugDescription) \(name.debugDescription)")
        if !pattern.isEmpty, pattern.allSatisfy({ $0 == "*" }) { fzCheck(a, "filemask-star", name.debugDescription) }
        // The rules as `FileMask` states them, worked out the slow way.
        fzCheck(
            a == referenceMaskMatches(pattern, name), "filemask-differs-from-rules",
            "mask \(pattern.debugDescription) name \(name.debugDescription): matcher \(a)")
        // Neither case nor the way an accent is written counts, in the mask or in the name.
        for other in [
            name.uppercased(), name.lowercased(), name.decomposedStringWithCanonicalMapping,
            name.precomposedStringWithCanonicalMapping
        ]
        where maskFolded(other) == maskFolded(name) {
            fzCheck(
                mask.matches(other) == a, "filemask-case-or-accent-form-counts",
                "mask \(pattern.debugDescription) name \(name.debugDescription) other \(other.debugDescription)")
        }
        fzCheck(
            FileMask(pattern.decomposedStringWithCanonicalMapping).matches(name) == a,
            "filemask-mask-accent-form-counts", "mask \(pattern.debugDescription) name \(name.debugDescription)")
    })

/// The form masks and names are compared in (the rule of the type: without case, accents composed).
func maskFolded(_ text: String) -> [UInt32] {
    text.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping.unicodeScalars.map(
        \.value)
}

/// `FileMask` by its documented rules, with no shortcuts: masks are separated by spaces or
/// semicolons; `*` is any run and `?` exactly one character (a Unicode scalar of the folded
/// name); everything else, brackets and backslashes included, stands for itself; `*` and `*.*`
/// match every name; a mask that ends with a dot is, for a name without a dot, the mask without it.
func referenceMaskMatches(_ pattern: String, _ name: String) -> Bool {
    let folded = maskFolded(pattern)
    let masks = folded.split(whereSeparator: { $0 == 0x20 || $0 == 0x3B }).map(Array.init)
    if masks.contains(where: { $0 == [0x2A] || $0 == [0x2A, 0x2E, 0x2A] }) { return true }
    let text = maskFolded(name)
    let hasDot = text.contains(0x2E)
    func wild(_ mask: [UInt32]) -> Bool {
        // reach[j]: the mask so far can take the first j characters of the name.
        var reach = [Bool](repeating: false, count: text.count + 1)
        reach[0] = true
        for token in mask {
            var next = [Bool](repeating: false, count: text.count + 1)
            if token == 0x2A {
                var any = false
                for j in 0...text.count {
                    any = any || reach[j]
                    next[j] = any
                }
            } else {
                for j in 0..<text.count where reach[j] && (token == 0x3F || token == text[j]) { next[j + 1] = true }
            }
            reach = next
        }
        return reach[text.count]
    }
    return masks.contains { mask in wild(!hasDot && mask.last == 0x2E ? Array(mask.dropLast()) : mask) }
}

// MARK: - items from fuzz bytes

let dir = URL(fileURLWithPath: "/fuzz/dir")
func lone(_ units: [UInt16]) -> String { NSString(characters: units, length: units.count) as String }
let trickyNames: [String] = [
    "a", "A", "a.txt", "A.TXT", "b.txt", "é", "e\u{301}", "É", "ｅ", "", ".", "..", ".hidden", "name.", "a.b.c", "a b",
    " a", "a ", "ß", "SS", "ss", "İ", "i", "I", "ı",
    "file10", "file9", "file09", "File10.TXT", String(repeating: "x", count: 300),
    String(repeating: "é", count: 200) + ".e\u{301}", "😀.png", "👨‍👩‍👧.jpg", "\u{0}", "a\u{0}b",
    "a\u{301}\u{302}\u{303}", "\u{FFFD}", "\u{FEFF}a", "a\u{200D}", "\u{202E}txt.exe", "가", "\u{1100}\u{1161}", "ǆ",
    "Ǆ", "ǅ", "ﬁ", "fi", "Å", "\u{212B}", "\u{F900}", "\u{8C48}",
    lone([0xD800]), lone([0x61, 0xDC00, 0x62]), lone([0xD83D]), lone([0xDE00, 0xD83D]), "~", "_", "-", "!", "0", "00",
    "a-b", "a_b", "ab", "a.B", "a.b", "Z", "z", "Ω", "ω"
]
let sizes: [Int64] = [0, 1, 2, 1_000, 1 << 32, .max, .max - 1, 1 << 62, 5, 5, 5]
let dates: [Date] = [
    Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_600_000_000), .distantPast, .distantFuture,
    Date(timeIntervalSinceReferenceDate: 0),
    Date(timeIntervalSinceReferenceDate: -0.0), Date(timeIntervalSinceReferenceDate: .infinity),
    Date(timeIntervalSinceReferenceDate: -.infinity),
    Date(timeIntervalSinceReferenceDate: 1e-300), Date(timeIntervalSinceReferenceDate: -1e-300),
    Date(timeIntervalSince1970: 1_600_000_000.5), Date(timeIntervalSince1970: -1)
]

/// One item: a flags byte, a name choice, sometimes the name's own bytes.
func nextItem(_ c: inout Choices, previous: String?, allowNaN: Bool = false) -> FileItem {
    let flags = c.byte()
    var name: String
    switch c.int(8) {
    case 0, 1, 2: name = trickyNames[c.int(trickyNames.count)]
    case 3: name = text(c.take(Int(c.byte()) % 24))
    case 4: name = previous ?? "dup"
    case 5: name = (previous ?? "é").decomposedStringWithCanonicalMapping
    case 6: name = (previous ?? "e\u{301}").precomposedStringWithCanonicalMapping

    default:
        let base = trickyNames[c.int(trickyNames.count)]
        name = c.bool() ? base.uppercased() : base + "." + trickyNames[c.int(trickyNames.count)]
    }
    if flags & 0x40 != 0, name.utf16.count < 40 { name = lone(Array(name.utf16) + [0xD800 + UInt16(c.byte())]) }
    var modified = dates[c.int(dates.count)]
    if allowNaN, flags & 0x80 != 0, c.int(4) == 0 { modified = Date(timeIntervalSinceReferenceDate: .nan) }
    let isDirectory = flags & 3 == 0
    return FileItem(
        url: dir.appendingPathComponent(name.isEmpty ? "_" : name), name: name, isDirectory: isDirectory,
        isPackage: isDirectory && flags & 4 != 0,
        isHidden: flags & 8 != 0, size: sizes[c.int(sizes.count)], modified: modified,
        computedSize: flags & 0x30 == 0x30 ? sizes[c.int(sizes.count)] : nil)
}

/// With `uniqueNames`, no two items have the same bytes for a name (as in a folder on a disk);
/// names that differ only in their writing (é composed and decomposed) stay.
var uniqueNames = true
func nextItems(_ c: inout Choices, max: Int = 48, besides: [FileItem] = []) -> [FileItem] {
    var out: [FileItem] = []
    var seen = Set(besides.map { Array($0.name.utf8) })
    let n = c.int(max)
    for _ in 0..<n where !c.atEnd {
        let item = nextItem(&c, previous: out.last?.name)
        if uniqueNames, !seen.insert(Array(item.name.utf8)).inserted { continue }
        out.append(item)
    }
    return out
}

func nextOrder(_ c: inout Choices) -> ListOrder {
    ListOrder(key: [SortKey.unsorted, .name, .ext, .size, .date][c.int(5)], descending: c.bool())
}

func describe(_ items: [FileItem]) -> String {
    items.prefix(40).map {
        "\($0.isFolder ? "[D]" : "")\(Array($0.name.utf16).map { String($0, radix: 16) }.joined(separator: " "))|\($0.size)|\($0.modified.timeIntervalSinceReferenceDate)"
    }.joined(separator: ", ")
}

/// Identity of an entry in a result: the object it came from is not kept, so the position in the input stands for it.
func tagged(_ items: [FileItem]) -> [FileItem] {
    // The url carries the index; nothing in the order looks at it.
    items.enumerated().map { index, item in
        FileItem(
            url: URL(fileURLWithPath: "/i/\(index)"), name: item.name, isDirectory: item.isDirectory,
            isPackage: item.isPackage, isHidden: item.isHidden,
            size: item.size, modified: item.modified, computedSize: item.computedSize)
    }
}
func ids(_ items: [FileItem]) -> [Int] { items.map { Int($0.url.lastPathComponent) ?? -1 } }

/// The defined order, by the definition alone: a stable sort with the comparison the kernel publishes.
func referenceSort(_ items: [FileItem], _ order: ListOrder, collator: NameCollator = .current) -> [FileItem] {
    var indexed = Array(items.enumerated())
    // insertion by binary merge: a merge sort that never asks for more than "a before b".
    func merge(_ a: [(offset: Int, element: FileItem)], _ b: [(offset: Int, element: FileItem)]) -> [(
        offset: Int, element: FileItem
    )] {
        var out: [(offset: Int, element: FileItem)] = []
        out.reserveCapacity(a.count + b.count)
        var (i, j) = (0, 0)
        while i < a.count, j < b.count {
            if Sorter.areInOrder(b[j].element, a[i].element, by: order, collator: collator) {
                out.append(b[j])
                j += 1
            } else {
                out.append(a[i])
                i += 1
            }
        }
        out.append(contentsOf: a[i...])
        out.append(contentsOf: b[j...])
        return out
    }
    func sort(_ x: ArraySlice<(offset: Int, element: FileItem)>) -> [(offset: Int, element: FileItem)] {
        if x.count <= 1 { return Array(x) }
        let mid = x.startIndex + x.count / 2
        return merge(sort(x[..<mid]), sort(x[mid...]))
    }
    indexed = sort(indexed[...])
    return indexed.map(\.element)
}

func isSorted(_ items: [FileItem], _ order: ListOrder) -> Int? {
    for i in items.indices.dropFirst() where Sorter.areInOrder(items[i], items[i - 1], by: order) { return i }
    return nil
}

/// Whether "before" is an order at all on these items: without that no sort has one answer.
func comparatorIsConsistent(_ items: [FileItem], _ order: ListOrder, collator: NameCollator = .current) -> Bool {
    let n = min(items.count, 14)
    func before(_ a: Int, _ b: Int) -> Bool { Sorter.areInOrder(items[a], items[b], by: order, collator: collator) }
    for i in 0..<n {
        for j in 0..<n {
            let ij = before(i, j)
            let ji = before(j, i)
            if ij, ji { return false }
            for k in 0..<n where ij && before(j, k) && !before(i, k) { return false }
            // equivalence is transitive as well
            if !ij, !ji {
                for k in 0..<n {
                    let jk = before(j, k)
                    let kj = before(k, j)
                    let ik = before(i, k)
                    let ki = before(k, i)
                    if !jk, !kj, ik || ki { return false }
                }
            }
        }
    }
    return true
}

/// The order of names as `Sorter` defines it: of two names that are not the same bytes exactly
/// one comes first (collation key, then the bytes), whatever the names are.
func checkNameOrder(_ items: [FileItem], collator: NameCollator, _ which: String) {
    let names = items.prefix(14).map(\.name)
    for a in names {
        for b in names {
            let ab = Sorter.compareNames(a, b, collator: collator)
            let ba = Sorter.compareNames(b, a, collator: collator)
            let same = Array(a.utf16) == Array(b.utf16)
            fzCheck(
                (ab == .orderedSame) == same, "sorter-names-equal-without-being-the-same" + which,
                "\(Array(a.utf16)) \(Array(b.utf16)): \(ab.rawValue)")
            fzCheck(
                ab.rawValue == -ba.rawValue, "sorter-names-order-not-antisymmetric" + which,
                "\(Array(a.utf16)) \(Array(b.utf16)): \(ab.rawValue) and \(ba.rawValue)")
        }
    }
}

let sorter = FuzzTarget(
    "sorter", maxLen: 2_048,
    seeds: {
        [
            Array(0..<200).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) },
            [1, 0, 30] + Array(repeating: UInt8(1), count: 120), [3, 1, 40] + (0..<160).map { UInt8($0) },
            [0x10, 2, 12] + (0..<90).map { UInt8(truncatingIfNeeded: 255 - $0) }
        ]
    },
    run: { bytes in
        uniqueNames = false
        var c = Choices(bytes)
        let mode = c.byte()
        let order = nextOrder(&c)
        var items = nextItems(&c)
        if mode & 0x0F == 0, !items.isEmpty {
            // Long enough for the parallel path: the same names again and again, with a counter in some.
            let basis = items
            var grown: [FileItem] = []
            grown.reserveCapacity(9_000)
            var k = 0
            while grown.count < 8_200 + Int(mode >> 4) * 40 {
                let it = basis[k % basis.count]
                let name = (k / basis.count) % 3 == 0 ? it.name : it.name + String(k % 97)
                grown.append(
                    FileItem(
                        url: it.url, name: name, isDirectory: it.isDirectory, isPackage: it.isPackage,
                        size: it.size &+ Int64(k % 5), modified: it.modified))
                k += 1
            }
            items = grown
        }
        items = tagged(items)
        let sorted = Sorter.sort(items, by: order)
        fzCheck(
            ids(sorted).sorted() == Array(items.indices), "sorter-not-a-permutation", "\(order) \(describe(items))")
        let plain = Sorter.sort(items, by: order, collator: .unavailable)
        fzCheck(
            ids(plain).sorted() == Array(items.indices), "sorter-not-a-permutation-nokeys",
            "\(order) \(describe(items))")
        let reference = referenceSort(items, order)
        // The order is defined by collation keys and then bytes, so "before" is an order in the strict
        // sense for any names, with the system's collator and with the fallback keys alike.
        fzCheck(
            comparatorIsConsistent(items, order), "sorter-comparison-is-not-an-order", "\(order) \(describe(items))")
        fzCheck(
            comparatorIsConsistent(items, order, collator: .unavailable), "sorter-comparison-is-not-an-order-nokeys",
            "\(order) \(describe(items))")
        checkNameOrder(items, collator: .current, "")
        checkNameOrder(items, collator: .unavailable, "-nokeys")
        var key: String { items.count > 60 || comparatorIsConsistent(items, order) ? "" : "-inconsistent-comparator" }
        if let at = isSorted(sorted, order) {
            fzFail(
                "sorter-out-of-order" + key,
                "\(order) at \(at): \(describe(Array(sorted[(at - 1)...at]))) of \(describe(items))")
        }
        fzCheck(
            ids(sorted) == ids(reference), "sorter-differs-from-definition" + key,
            "\(order)\n got \(ids(sorted).prefix(60))\nwant \(ids(reference).prefix(60))\n\(describe(items))")
        // Without the system's collator the order is that of the fallback keys: its own definition.
        // (A second slow sort of the 8,000-item lists would take the time of the run: they are compared up to 1,000.)
        let plainReference = items.count <= 1_000 ? referenceSort(items, order, collator: .unavailable) : plain
        fzCheck(
            ids(plain) == ids(plainReference), "sorter-nokeys-differs-from-definition" + key,
            "\(order)\n got \(ids(plain).prefix(60))\nwant \(ids(plainReference).prefix(60))\n\(describe(items))")
        guard items.count <= 200 else { return }
        // Turning the order round gives what sorting anew gives.
        let other = c.bool() ? ListOrder(key: order.key, descending: !order.descending) : nextOrder(&c)
        let resorted = Sorter.resort(sorted, from: order, to: other)
        fzCheck(
            ids(resorted) == ids(Sorter.sort(sorted, by: other)), "resort-differs-from-sort" + key,
            "\(order) -> \(other) \(describe(sorted))")
        // Batches merged into a sorted list.
        let cut = items.isEmpty ? 0 : c.int(items.count + 1)
        let first = Sorter.sort(Array(items[..<cut]), by: order)
        let second = Sorter.sort(Array(items[cut...]), by: order)
        let merged = Sorter.merge(first, with: second, by: order)
        fzCheck(
            ids(merged).sorted() == Array(items.indices), "merge-not-a-permutation",
            "\(order) cut \(cut) \(describe(items))")
        if let at = isSorted(merged, order) {
            fzFail(
                "merge-out-of-order" + key,
                "\(order) cut \(cut) at \(at): \(describe(Array(merged[(at - 1)...at]))) of \(describe(items))")
        }
        var list = SortedFileList(order: order)
        var at = 0
        while at < items.count {
            let n = 1 + c.int(9)
            list.add(Array(items[at..<min(items.count, at + n)]))
            at += n
        }
        fzCheck(
            ids(list.items).sorted() == Array(items.indices), "sortedlist-not-a-permutation",
            "\(order) \(describe(items))")
        if let at = isSorted(list.items, order) {
            fzFail(
                "sortedlist-out-of-order" + key,
                "\(order) at \(at): \(describe(Array(list.items[(at - 1)...at]))) of \(describe(items))")
        }
        if order.key != .unsorted {
            fzCheck(
                ids(list.items) == ids(reference), "sortedlist-differs-from-definition" + key,
                "\(order)\n got \(ids(list.items).prefix(60))\nwant \(ids(reference).prefix(60))\n\(describe(items))")
        }
    })

// MARK: - PanelModel

func same(_ a: [FileItem], _ b: [FileItem]) -> Bool {
    a.count == b.count
        && zip(a, b).allSatisfy {
            ExactName.areSame($0.name, $1.name) && $0.isDirectory == $1.isDirectory && $0.size == $1.size
                && $0.computedSize == $1.computedSize
        }
}

func checkModel(_ model: PanelModel, last: [FileItem]?, op: String, ordered: Bool) {
    let items = model.items
    let listed = model.listedItems
    let rows = model.rowCount
    let offset = model.hasParentRow ? 1 : 0
    fzCheck(rows == items.count + offset, "panel-rowcount", op)
    fzCheck(
        model.cursor >= 0 && model.cursor <= max(rows - 1, 0), "panel-cursor-out-of-range",
        "\(op): cursor \(model.cursor) of \(rows) rows")
    // What is shown is what was listed, filtered.
    let shown = model.filter.map { f in listed.filter(f.matches) } ?? listed
    if !same(items, shown) {
        let at =
            zip(items, shown).enumerated().first { !same([$0.element.0], [$0.element.1]) }?.offset
            ?? min(items.count, shown.count)
        fzFail(
            "panel-items-not-filtered-list" + (uniqueNames ? "" : "-identical-names"),
            "\(op): \(items.count) shown, \(shown.count) pass the filter; first difference at \(at): shown \(items.indices.contains(at) ? describe([items[at]]) + " computed \(String(describing: items[at].computedSize))" : "-") listed \(shown.indices.contains(at) ? describe([shown[at]]) + " computed \(String(describing: shown[at].computedSize))" : "-")\nall listed: \(describe(model.listedItems))"
        )
    }
    if ordered, let at = isSorted(listed, model.sort) {
        fzFail("panel-list-out-of-order", "\(op) \(model.sort) at \(at): \(describe(listed))")
    }
    if let last {
        let a = last.map { Array($0.name.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
        let b = listed.map { Array($0.name.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
        fzCheck(a == b, "panel-list-not-the-listing", "\(op): \(describe(listed)) vs \(describe(last))")
    }
    // Selection.
    // A mark belongs to an entry (a place in the list), not to a name: two entries of one name, or of
    // names that read the same, can be marked one without the other.
    let names = items.map { Array($0.name.utf8) }
    let identical = Set(names).count < names.count
    var markedRows = 0
    var markedNames: [[UInt16]] = []
    for row in 0..<rows where model.isSelected(row: row) {
        markedRows += 1
        if let it = model.item(atRow: row) { markedNames.append(Array(it.name.utf16)) }
    }
    fzCheck(model.isSelected(row: 0) == false || !model.hasParentRow, "panel-parent-row-marked", op)
    fzCheck(
        model.selectionCount == markedRows, "panel-selectioncount-vs-marked-rows",
        "\(op): count \(model.selectionCount), \(markedRows) rows")
    fzCheck(model.hasSelection == (markedRows > 0), "panel-hasselection", op)
    // `selectedNames`: one per marked entry, as written, in the order of the list.
    fzCheck(
        model.selectedNames.map { Array($0.utf16) } == markedNames, "panel-selectednames-vs-marked-rows",
        "\(op): \(model.selectedNames.count) names, \(markedRows) rows")
    // `selection` is a set of names: one member for names that read the same (documented), never more
    // members than marks, and exactly the marked names.
    let selection = model.selection
    fzCheck(
        selection.count <= model.selectionCount && selection.isEmpty == (markedRows == 0), "panel-selection-set-size",
        "\(op): \(selection.count) vs \(model.selectionCount)")
    fzCheck(selection == Set(model.selectedNames), "panel-selection-set-vs-selectednames", op)
    for (index, item) in items.enumerated() where !identical {
        fzCheck(
            model.isSelected(item) == model.isSelected(row: index + offset), "panel-isselected-item-vs-row",
            "\(op): row \(index + offset) \(describe([item]))")
    }
    // The operands are the marked entries; without marks, the entry under the cursor.
    let operands = model.operands()
    if markedRows > 0 {
        fzCheck(
            operands.map { Array($0.name.utf16) } == markedNames, "panel-operands-vs-marked-rows",
            "\(op): \(operands.count) operands, \(markedRows) marked rows")
    } else {
        fzCheck(operands.count <= 1, "panel-operands-without-marks", "\(op): \(operands.count)")
    }
    fzCheck(model.hasOperands == !operands.isEmpty, "panel-hasoperands", op)
    fzCheck(model.hasOperandFile == operands.contains { !$0.isDirectory }, "panel-hasoperandfile", op)
    // Totals.
    var want = PanelModel.Totals()
    for (index, item) in items.enumerated() {
        let size = item.isFolder ? (item.computedSize ?? 0) : item.size
        want.totalBytes = want.totalBytes.addingSaturated(size)
        if item.isFolder { want.totalFolders += 1 } else { want.totalFiles += 1 }
        if model.isSelected(row: index + offset) {
            want.selectedBytes = want.selectedBytes.addingSaturated(size)
            if item.isFolder { want.selectedFolders += 1 } else { want.selectedFiles += 1 }
        }
    }
    let have = model.totals
    fzCheck(have == want, "panel-totals", "\(op): have \(have) want \(want) of \(describe(items))")
    // Rows by name.
    for (index, item) in items.enumerated() {
        guard let row = model.row(ofName: item.name) else {
            fzFail("panel-row-of-name-nil", "\(op): \(describe([item])) at \(index) of \(describe(items))")
        }
        guard let found = model.item(atRow: row) else { fzFail("panel-row-of-name-out-of-range", "\(op): row \(row)") }
        fzCheck(
            ExactName.areSame(found.name, item.name), "panel-row-of-name-other-item",
            "\(op): asked \(describe([item])) got \(describe([found]))")
        if !identical {
            fzCheck(row == index + offset, "panel-row-of-name-wrong-row", "\(op): \(row) vs \(index + offset)")
        }
    }
    fzCheck(model.row(ofName: "\u{1}no such name\u{2}") == nil, "panel-row-of-missing-name", op)
    _ = model.operands()
    _ = model.hasOperands
    _ = model.hasOperandFile
    _ = model.cursorItem
    _ = model.cursorFile
    _ = model.parentTarget
    _ = model.rootTarget
    _ = model.savedSelection
}

func panelTarget(_ name: String, unique: Bool) -> FuzzTarget {
    FuzzTarget(
        name, maxLen: 3_000,
        seeds: {
            [
                (0..<400).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 3) },
                (0..<600).map { UInt8(truncatingIfNeeded: $0 &* 101 &+ 17) }, [UInt8](repeating: 7, count: 300),
                (0..<500).map { UInt8(truncatingIfNeeded: ($0 * $0) >> 3) }
            ]
        },
        run: { bytes in
            var c = Choices(bytes)
            shuffler = Shuffler(s: UInt64(bytes.count) &+ 42)
            uniqueNames = unique
            let model = PanelModel(directory: dir, sort: nextOrder(&c))
            var changes = 0
            model.onChange = { _ in changes += 1 }
            var last: [FileItem]?
            var snapshots: [(PanelModel.Snapshot, [FileItem]?)] = []
            var ordered = true
            func listing(_ items: [FileItem], other: Bool = false) -> Listing {
                let d = other ? dir.appendingPathComponent("sub") : dir
                return Listing(
                    directory: d, items: items, parent: c.bool() ? d.deletingLastPathComponent() : nil,
                    root: URL(fileURLWithPath: "/"))
            }
            func name() -> String {
                let items = model.listedItems
                if !items.isEmpty, c.int(4) != 0 { return items[c.int(items.count)].name }
                return trickyNames[c.int(trickyNames.count)]
            }
            func row() -> Int { c.int(model.rowCount + 4) - 2 }
            var steps = 0
            while !c.atEnd, steps < 60 {
                steps += 1
                let op = c.int(26)
                var what = "op \(op)"
                switch op {
                case 0:
                    let items = nextItems(&c)
                    last = items
                    ordered = true
                    model.show(
                        listing(items, other: c.int(5) == 0), focus: c.bool() ? name() : nil, complete: c.bool())

                case 1:
                    let items = nextItems(&c)
                    last = items
                    ordered = true
                    model.showRemembered(listing(items), focus: c.bool() ? name() : nil)

                case 2:
                    guard model.isListed else { continue }
                    let more = model.listedItems + nextItems(&c, max: 12, besides: model.listedItems)
                    let order = c.bool() ? model.sort : nextOrder(&c)
                    last = more
                    model.extend(to: Sorter.sort(more, by: order), sortedBy: order)
                    if c.bool() { model.finishLoading() }

                case 3, 4:
                    guard model.isListed else { continue }
                    var items = model.listedItems
                    for _ in 0..<c.int(4) where !items.isEmpty { items.remove(at: c.int(items.count)) }
                    items += nextItems(&c, max: 6, besides: items)
                    if c.bool() { items.shuffle(using: &shuffler) }
                    last = items
                    ordered = true
                    let presorted = op == 4
                    _ = model.update(
                        with: listing(presorted ? Sorter.sort(items, by: model.sort) : items),
                        focus: c.bool() ? name() : nil, presorted: presorted ? model.sort : nil)

                case 5:
                    model.setSort(nextOrder(&c))
                    ordered = true

                case 6:
                    let order = nextOrder(&c)
                    model.setSort(order, presorted: c.int(6) == 0 ? [] : Sorter.sort(model.listedItems, by: order))
                    ordered = true

                case 7:
                    let masks = ["*.txt", "*", "a*", "*é*", "*.", "", "[a-c]*", "*e\u{301}*", "?", "*.TXT;*.png"]
                    let mask = masks[c.int(masks.count)]
                    what += " filter \(mask)"
                    model.setFilter(
                        c.int(4) == 0 ? nil : PanelFilter.mask(mask), narrowing: c.bool() && model.filter == nil)

                case 8:
                    let filter: PanelFilter? = c.int(4) == 0 ? nil : PanelFilter(title: "size") { $0.size > 1 }
                    let stale = c.int(4) == 0
                    _ = model.setFilter(
                        filter, prefiltered: stale ? [] : PanelModel.filtered(model.listedItems, by: filter),
                        listVersion: model.listVersion - (stale ? 1 : 0))

                case 9: model.toggleSelection(row: row())

                case 10:
                    let a = row()
                    let b = row()
                    model.setSelected(c.bool(), rows: min(a, b)...max(a, b))

                case 11: model.setSelected(c.bool(), names: (0..<c.int(5)).map { _ in name() })
                case 12: model.setSelection(names: (0..<c.int(6)).map { _ in name() })
                case 13: model.selectAll()
                case 14: model.clearSelection()
                case 15: model.invertSelection()
                case 16: model.select(mask: ["*.txt", "*", "a*", "*é*", "*."][c.int(5)], select: c.bool())
                case 17: model.saveSelection()
                case 18: model.restoreSelection()
                case 19: model.deselect((0..<c.int(4)).map { _ in name() })
                case 20: model.setComputedSize(sizes[c.int(sizes.count)], forName: name())

                case 21:
                    model.setComputedSizes((0..<c.int(4)).map { _ in (name: name(), size: sizes[c.int(sizes.count)]) })

                case 22: snapshots.append((model.snapshot(), last))

                case 23:
                    guard !snapshots.isEmpty else { continue }
                    let (snapshot, then) = snapshots[c.int(snapshots.count)]
                    model.restore(snapshot)
                    last = then
                    // A snapshot holds the lists as they were; the order and filter of today are not applied to them.
                    ordered = false

                case 24: model.moveCursor(to: row() * (c.int(8) == 0 ? 1_000_000 : 1))
                default: model.setShowHidden(c.bool())
                }
                if op == 23 || !ordered {
                    // After a restore only what does not depend on today's order and filter holds.
                    continue
                }
                if case 20...21 = op { last = nil }
                checkModel(model, last: [7, 8].contains(op) ? nil : last, op: what, ordered: ordered)
            }
        })
}
let panel = panelTarget("panel", unique: true)
let panelDup = panelTarget("paneldup", unique: false)

struct Shuffler: RandomNumberGenerator {
    var s: UInt64 = 42
    mutating func next() -> UInt64 {
        s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return s
    }
}
var shuffler = Shuffler()

let selfTest = FuzzTarget(
    "selftest", maxLen: 64, seeds: { [Array("hello world".utf8)] },
    run: { b in
        if b.count > 3, b[0] == 0x43, b[1] == 0x52 {
            let a = [1, 2, 3]
            _ = a[Int(b[2])]
        }
        if b.count > 5, b[0] == 0x48, b[1] == 0x41 { while true {} }
    })

fuzzMain([fileMask, sorter, panel, panelDup, selfTest])
