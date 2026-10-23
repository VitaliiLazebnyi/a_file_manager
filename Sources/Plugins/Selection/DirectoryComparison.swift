import AFMKernel
import Foundation

/// Compare Directories and Mark Newer (spec 09 › Compare directories and Mark newer): which
/// entries of two lists differ.
///
/// Works on the lists the panels hold; pure, any thread.
internal enum DirectoryComparison {
    /// What counts as a difference; the raw value is the `.index` of `cm_CompareDirs`.
    internal enum Mode: Int {
        /// Only what is missing on the other side (`cm_CompareDirs 1`).
        case missing = 1
        /// Missing or newer: what Mark Newer, Hide Same Files marks.
        case newer = 3
        /// Missing on the other side, newer, or of another size at the same time
        /// (`cm_CompareDirs 0`).
        case newerOrDifferent = 0
        /// Another size, or missing (`cm_CompareDirs 2`).
        case sizeOrMissing = 2
    }

    /// How two lists are compared.
    internal struct Options {
        /// What counts as a difference.
        internal var mode = Mode.newer
        /// Whether folders that the other side does not have are marked too.
        internal var withSubdirectories = false
        /// Whether times exactly one hour apart count as equal.
        internal var ignoringOneHour = false
        /// Whether names are paired without regard to case, for a volume that does not tell
        /// `Photo.JPG` from `photo.jpg`.
        internal var foldingCase = false
    }

    /// The entries to mark on each side, by name in list order: two entries whose names differ
    /// only in Unicode normalisation are two marks. `left`, `right` and `same` read them as sets.
    internal struct Marks: Equatable {
        /// The names to mark in the left list.
        internal var leftNames: [String] = []
        /// The names to mark in the right list.
        internal var rightNames: [String] = []
        /// Present on both sides and the same: files of equal size and time, and folders.
        internal var sameNames: [String] = []

        /// `leftNames` as a set.
        internal var left: Set<String> { Set(leftNames) }
        /// `rightNames` as a set.
        internal var right: Set<String> { Set(rightNames) }
        /// `sameNames` as a set.
        internal var same: Set<String> { Set(sameNames) }

        /// No marks.
        internal init() {
            // The lists start empty.
        }

        /// Marks of the given sets, in no particular order.
        internal init(left: Set<String>, right: Set<String>, same: Set<String>) {
            (leftNames, rightNames, sameNames) = (Array(left), Array(right), Array(same))
        }

        /// Whether the two mark the same names, regardless of order.
        internal static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.left == rhs.left && lhs.right == rhs.right && lhs.same == rhs.same
        }
    }

    /// The same as places in the two lists that were compared.
    internal struct IndexMarks {
        /// The places to mark in the left list, ascending.
        internal var left: [Int] = []
        /// The places to mark in the right list, ascending.
        internal var right: [Int] = []
        /// The entries (of the left and of the right list) that are the same on both sides, in
        /// pairs: `sameLeft[i]` and `sameRight[i]` are the two of one pair.
        internal var sameLeft: [Int] = []
        /// The right-hand places of the pairs in `sameLeft`.
        internal var sameRight: [Int] = []

        /// Marks two paired entries of the same kind, the one at `position` on the left and the
        /// one at `index` on the right, as the options say.
        internal mutating func mark(
            pair position: Int,
            _ index: Int,
            of item: FileItem,
            _ other: FileItem,
            options: Options
        ) {
            guard !item.isFolder else {
                sameLeft.append(position)
                sameRight.append(index)
                return
            }
            var difference =
                Int64(item.modified.timeIntervalSince1970.rounded(.down))
                - Int64(other.modified.timeIntervalSince1970.rounded(.down))
            if options.ignoringOneHour, abs(difference) == 3_600 { difference = 0 }
            let sameSize = item.size == other.size
            if difference == 0, sameSize {
                sameLeft.append(position)
                sameRight.append(index)
            }
            switch options.mode {
            case .missing:
                break

            case .sizeOrMissing:
                if !sameSize {
                    left.append(position)
                    right.append(index)
                }

            case .newer, .newerOrDifferent:
                if difference > 0 { left.append(position) }
                if difference < 0 { right.append(index) }
                if options.mode == .newerOrDifferent, difference == 0, !sameSize {
                    left.append(position)
                    right.append(index)
                }
            }
        }
    }

    /// The marks by name; see `compareIndices`.
    internal static func compare(left: [FileItem], right: [FileItem], options: Options) -> Marks {
        let found = compareIndices(left: left, right: right, options: options) { false }
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

    /// The marks as places in the two lists.
    ///
    /// Times are compared in whole seconds, since not every file system keeps more. `cancelled` is
    /// looked at every few thousand entries; a cancelled comparison returns what it had.
    internal static func compareIndices(
        left: [FileItem],
        right: [FileItem],
        options: Options,
        cancelled: () -> Bool
    ) -> IndexMarks {
        var marks = IndexMarks()
        let (partner, isComplete) = partners(
            left: left,
            right: right,
            foldingCase: options.foldingCase,
            cancelled: cancelled
        )
        guard isComplete else {
            return marks
        }
        var paired = Set<Int>()
        paired.reserveCapacity(min(left.count, right.count))
        for (position, item) in left.enumerated() {
            if position & 0xFFF == 0, cancelled() {
                return marks
            }
            // A file and a folder of the same name have nothing in common.
            guard let index = partner[position], right[index].isFolder == item.isFolder else {
                if !item.isFolder || options.withSubdirectories { marks.left.append(position) }
                continue
            }
            paired.insert(index)
            marks.mark(pair: position, index, of: item, right[index], options: options)
        }
        for (index, item) in right.enumerated() where !paired.contains(index) {
            if !item.isFolder || options.withSubdirectories { marks.right.append(index) }
        }
        // The right-hand marks of paired entries came in the order of the left list.
        marks.right.sort()
        return marks
    }

    /// For each entry of `left`, the place of its partner in `right`, or nil; not complete when
    /// `cancelled` said so before the pairing was done.
    ///
    /// Names are paired by their exact bytes first, so that twins that differ only in
    /// normalisation each find their own; a name with no such partner takes the first one that
    /// reads the same.
    private static func partners(
        left: [FileItem],
        right: [FileItem],
        foldingCase: Bool,
        cancelled: () -> Bool
    ) -> (partner: [Int?], isComplete: Bool) {
        let key = { (name: String) in foldingCase ? name.precomposedStringWithCanonicalMapping.lowercased() : name }
        var exactOthers: [NameBytes: Int] = [:]
        exactOthers.reserveCapacity(right.count)
        for (index, item) in right.enumerated() {
            if index & 0xFFF == 0, cancelled() {
                return ([], false)
            }
            let bytes = NameBytes(key(item.name))
            if exactOthers[bytes] == nil { exactOthers[bytes] = index }
        }
        var partner = [Int?](repeating: nil, count: left.count)
        var taken = Set<Int>()
        for (index, item) in left.enumerated() {
            if index & 0xFFF == 0, cancelled() {
                return ([], false)
            }
            if let other = exactOthers[NameBytes(key(item.name))], taken.insert(other).inserted {
                partner[index] = other
            }
        }
        // Only what found no partner by its bytes is looked at again by the way it reads.
        if taken.count < right.count, taken.count < left.count {
            var readAlike: [String: [Int]] = [:]
            for (index, item) in right.enumerated() where !taken.contains(index) {
                readAlike[key(item.name), default: []].append(index)
            }
            for (index, item) in left.enumerated() where partner[index] == nil {
                if let other = readAlike[key(item.name)]?.first(where: { taken.insert($0).inserted }) {
                    partner[index] = other
                }
            }
        }
        return (partner, true)
    }
}
