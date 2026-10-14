/// A name as it is written: equal only to a name of the same bytes, where two `String`s are equal
/// as soon as they read the same (`é` as one character, or as `e` and an accent).
///
/// What the marks of a panel go by, so that of two entries whose names differ only in that, on a
/// volume that keeps both, each has its own.
internal struct ExactName: Hashable, Sendable {
    /// The name, its UTF-8 in one piece.
    internal let name: String

    /// The name as it is written.
    internal init(_ name: String) {
        var name = name
        // Nearly every name is in one piece of UTF-8 already; then this does nothing.
        name.makeContiguousUTF8()
        self.name = name
    }

    /// Whether two names are the same bytes.
    internal static func == (lhs: Self, rhs: Self) -> Bool { areSame(lhs.name, rhs.name) }

    /// Whether two names are the same bytes.
    internal static func areSame(_ lhs: String, _ rhs: String) -> Bool {
        let same = lhs.utf8.withContiguousStorageIfAvailable { first in
            rhs.utf8.withContiguousStorageIfAvailable { second in
                first.count == second.count && first.elementsEqual(second)
            }
        }
        // A name whose UTF-8 is not in one piece (a string the system bridged) is walked.
        return same.flatMap(\.self) ?? lhs.utf8.elementsEqual(rhs.utf8)
    }

    /// Feeds the bytes of a name to a hasher.
    internal static func combine(_ name: String, into hasher: inout Hasher) {
        // A name whose UTF-8 is not in one piece is put in one first.
        var bytes = name
        bytes.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }

    /// Hashes the name's bytes, as `==` compares them.
    internal func hash(into hasher: inout Hasher) {
        Self.combine(name, into: &hasher)
    }
}
