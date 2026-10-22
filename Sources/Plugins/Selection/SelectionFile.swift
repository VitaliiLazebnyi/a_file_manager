import AFMKernel
import Foundation

/// The file a selection is saved to and loaded from (spec 19 › Selection files): one name per
/// line without a path, folders with a trailing `\`, CRLF between the lines and none after
/// the last.
///
/// Pure functions, usable on any thread.
internal enum SelectionFile {
    internal enum Encoding {
        /// UTF-16 LE with a byte-order mark (`cm_SaveSelectionToFileW`, and the default).
        case unicode
        /// Windows-1252 (`cm_SaveSelectionToFileA`); characters outside it are approximated.
        case ansi
    }

    internal static func encode(_ items: [FileItem], as encoding: Encoding) -> Data {
        let text = items.map { $0.isFolder ? $0.name + "\\" : $0.name }.joined(separator: "\r\n")
        switch encoding {
        case .unicode:
            return Data([0xFF, 0xFE]) + Data(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })

        case .ansi:
            return windows1252(text)
        }
    }

    /// The text in Windows-1252, one character at a time.
    ///
    /// A character outside it is written as its base letter where it has one (`ą` as `a`), else as
    /// `?`. Foundation's lossy conversion of the whole text is not used: for some names (`U+3000
    /// U+0300`) it raises an exception that nothing catches.
    internal static func windows1252(_ text: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var known: [UInt32: UInt8] = [:]
        func code(_ scalar: Unicode.Scalar) -> UInt8? {
            guard let data = String(scalar).data(using: .windowsCP1252, allowLossyConversion: false), data.count == 1
            else { return nil }
            return data[data.startIndex]
        }
        for scalar in text.unicodeScalars {
            if scalar.value < 0x80 {
                bytes.append(UInt8(scalar.value))
            } else if let byte = known[scalar.value] {
                bytes.append(byte)
            } else {
                let byte =
                    code(scalar) ?? String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars.first
                    .flatMap(
                        code
                    ) ?? UInt8(ascii: "?")
                known[scalar.value] = byte
                bytes.append(byte)
            }
        }
        return Data(bytes)
    }

    /// The text of a selection file: UTF-16 or UTF-8 by its byte-order mark, else UTF-8 when
    /// the bytes are valid UTF-8, else Windows-1252.
    internal static func text(from data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    }

    /// The names a text lists, one per line, that are among `known`.
    ///
    /// A line may be a name, a folder's name with a trailing `\` or `/`, or a full path, of which
    /// the last part counts: so the lists of *Copy Names To Clipboard* can be loaded as well.
    internal static func names(in text: String, among known: Set<String>) -> Set<String> {
        Set(listed(in: text, among: known))
    }

    /// The same in the order of the lines, each as the text writes it: a name that reads like
    /// two entries' names still finds the one written exactly like it (`PanelModel.setSelection(names:)`).
    internal static func listed(in text: String, among known: Set<String>) -> [String] {
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var name = String(line)
            if known.contains(name) {
                names.append(name)
                continue
            }
            while let last = name.last, last == "\\" || last == "/" { name.removeLast() }
            if !known.contains(name), let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
                name = String(name[name.index(after: slash)...])
            }
            if known.contains(name) { names.append(name) }
        }
        return names
    }
}

/// A name that is equal to another only when it is written with the same bytes (a `String`
/// treats `é` and `e` + U+0301 as one name).
///
/// Hashing and comparing go over the UTF-8 in place.
internal struct NameBytes: Hashable {
    internal let name: String

    internal init(_ name: String) {
        var name = name
        // Nearly every name is in one piece of UTF-8 already; then this does nothing.
        name.makeContiguousUTF8()
        self.name = name
    }

    internal static func == (a: Self, b: Self) -> Bool {
        // The copies share the names' storage, which is one piece of UTF-8 already (`init`).
        var (first, second) = (a.name, b.name)
        return first.withUTF8 { one in
            second.withUTF8 { other in
                one.count == other.count
                    && (one.isEmpty || memcmp(one.baseAddress!, other.baseAddress!, one.count) == 0)
            }
        }
    }

    internal func hash(into hasher: inout Hasher) {
        var name = name
        name.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

/// Compare Directories and Mark Newer (spec 09 › Compare directories and Mark newer): which
/// entries of two lists differ.
///
/// Works on the lists the panels hold; pure, any thread.
internal enum DirectoryComparison {
    internal enum Mode: Int {
        /// Missing on the other side, newer, or of another size at the same time
        /// (`cm_CompareDirs 0`).
        case newerOrDifferent = 0
        /// Only what is missing on the other side (`cm_CompareDirs 1`).
        case missing = 1
        /// Another size, or missing (`cm_CompareDirs 2`).
        case sizeOrMissing = 2
        /// Missing or newer: what Mark Newer, Hide Same Files marks.
        case newer = 3
    }

    /// The entries to mark on each side, by name in list order: two entries whose names differ
    /// only in Unicode normalisation are two marks. `left`, `right` and `same` read them as sets.
    internal struct Marks: Equatable {
        internal var leftNames: [String] = []
        internal var rightNames: [String] = []
        /// Present on both sides and the same: files of equal size and time, and folders.
        internal var sameNames: [String] = []

        internal init() {}
        internal init(left: Set<String>, right: Set<String>, same: Set<String>) {
            (leftNames, rightNames, sameNames) = (Array(left), Array(right), Array(same))
        }

        internal var left: Set<String> { Set(leftNames) }
        internal var right: Set<String> { Set(rightNames) }
        internal var same: Set<String> { Set(sameNames) }

        internal static func == (a: Self, b: Self) -> Bool {
            a.left == b.left && a.right == b.right && a.same == b.same
        }
    }

    /// The same as places in the two lists that were compared.
    internal struct IndexMarks {
        internal var left: [Int] = []
        internal var right: [Int] = []
        /// The entries (of the left and of the right list) that are the same on both sides, in
        /// pairs: `sameLeft[i]` and `sameRight[i]` are the two of one pair.
        internal var sameLeft: [Int] = []
        internal var sameRight: [Int] = []
    }

    internal static func compare(
        left: [FileItem],
        right: [FileItem],
        mode: Mode = .newer,
        withSubdirectories: Bool = false,
        ignoringOneHour: Bool = false,
        foldingCase: Bool = false
    ) -> Marks {
        let found = compareIndices(
            left: left,
            right: right,
            mode: mode,
            withSubdirectories: withSubdirectories,
            ignoringOneHour: ignoringOneHour,
            foldingCase: foldingCase
        )
        var marks = Marks()
        marks.leftNames = found.left.map { left[$0].name }
        marks.rightNames = found.right.map { right[$0].name }
        // Where a name was paired with one that only reads the same, both writings are in it.
        for (one, other) in zip(found.sameLeft, found.sameRight) {
            marks.sameNames.append(left[one].name)
            if !left[one].name.utf8.elementsEqual(right[other].name.utf8) { marks.sameNames.append(right[other].name) }
        }
        return marks
    }

    /// `withSubdirectories` also marks folders that the other side does not have.
    ///
    /// With `ignoringOneHour`, times exactly one hour apart count as equal. Times are compared in
    /// whole seconds, since not every file system keeps more. With `foldingCase` (a volume that
    /// does not tell `Photo.JPG` from `photo.jpg`) names are paired without regard to case.
    /// `cancelled` is looked at every few thousand entries; a cancelled comparison returns what it
    /// had.
    internal static func compareIndices(
        left: [FileItem],
        right: [FileItem],
        mode: Mode = .newer,
        withSubdirectories: Bool = false,
        ignoringOneHour: Bool = false,
        foldingCase: Bool = false,
        cancelled: () -> Bool = { false }
    ) -> IndexMarks {
        var marks = IndexMarks()
        func key(_ name: String) -> String {
            foldingCase ? name.precomposedStringWithCanonicalMapping.lowercased() : name
        }
        // Names are paired by their exact bytes first, so that twins that differ only in
        // normalisation each find their own; a name with no such partner takes the first one
        // that reads the same.
        func exact(_ name: String) -> NameBytes { NameBytes(foldingCase ? key(name) : name) }
        var exactOthers: [NameBytes: Int] = [:]
        exactOthers.reserveCapacity(right.count)
        for (index, item) in right.enumerated() {
            if index & 0xFFF == 0, cancelled() {
                return marks
            }
            let bytes = exact(item.name)
            if exactOthers[bytes] == nil { exactOthers[bytes] = index }
        }
        var partner = [Int?](repeating: nil, count: left.count)
        var taken = Set<Int>()
        for (index, item) in left.enumerated() {
            if index & 0xFFF == 0, cancelled() {
                return marks
            }
            if let other = exactOthers[exact(item.name)], taken.insert(other).inserted { partner[index] = other }
        }
        // Only what found no partner by its bytes is looked at again by the way it reads.
        var readAlike: [String: [Int]] = [:]
        if taken.count < right.count, taken.count < left.count {
            for (index, item) in right.enumerated() where !taken.contains(index) {
                readAlike[key(item.name), default: []].append(index)
            }
            for (index, item) in left.enumerated() where partner[index] == nil {
                if let other = readAlike[key(item.name)]?.first(where: { taken.insert($0).inserted }) {
                    partner[index] = other
                }
            }
        }
        var paired = Set<Int>()
        paired.reserveCapacity(taken.count)
        func markSame(_ position: Int, _ other: Int) {
            marks.sameLeft.append(position)
            marks.sameRight.append(other)
        }
        for (position, item) in left.enumerated() {
            if position & 0xFFF == 0, cancelled() {
                return marks
            }
            // A file and a folder of the same name have nothing in common.
            guard let index = partner[position], right[index].isFolder == item.isFolder else {
                if !item.isFolder || withSubdirectories { marks.left.append(position) }
                continue
            }
            let other = right[index]
            paired.insert(index)
            if item.isFolder {
                markSame(position, index)
                continue
            }
            var difference =
                Int64(item.modified.timeIntervalSince1970.rounded(.down))
                - Int64(other.modified.timeIntervalSince1970.rounded(.down))
            if ignoringOneHour, abs(difference) == 3_600 { difference = 0 }
            let sameSize = item.size == other.size
            if difference == 0, sameSize { markSame(position, index) }
            switch mode {
            case .missing:
                break

            case .sizeOrMissing:
                if !sameSize {
                    marks.left.append(position)
                    marks.right.append(index)
                }

            case .newer, .newerOrDifferent:
                if difference > 0 { marks.left.append(position) }
                if difference < 0 { marks.right.append(index) }
                if mode == .newerOrDifferent, difference == 0, !sameSize {
                    marks.left.append(position)
                    marks.right.append(index)
                }
            }
        }
        for (index, item) in right.enumerated() where !paired.contains(index) && (!item.isFolder || withSubdirectories)
        {
            marks.right.append(index)
        }
        // The right-hand marks of paired entries came in the order of the left list.
        marks.right.sort()
        return marks
    }
}
