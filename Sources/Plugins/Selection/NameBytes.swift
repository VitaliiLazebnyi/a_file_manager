import Darwin.C

/// A name that is equal to another only when it is written with the same bytes (a `String`
/// treats `é` and `e` + U+0301 as one name).
///
/// Hashing and comparing go over the UTF-8 in place.
internal struct NameBytes: Hashable {
    /// The name, held as one piece of UTF-8.
    internal let name: String

    /// Wraps a name, making its storage one piece of UTF-8 if it is not already.
    internal init(_ name: String) {
        var contiguous = name
        // Nearly every name is in one piece of UTF-8 already; then this does nothing.
        contiguous.makeContiguousUTF8()
        self.name = contiguous
    }

    /// Whether the two names have the same bytes.
    internal static func == (lhs: Self, rhs: Self) -> Bool {
        // The copies share the names' storage, which is one piece of UTF-8 already (`init`).
        var (first, second) = (lhs.name, rhs.name)
        return first.withUTF8 { one in
            second.withUTF8 { other in
                one.count == other.count
                    && (one.isEmpty || memcmp(one.baseAddress, other.baseAddress, one.count) == 0)
            }
        }
    }

    /// Feeds the bytes of the name to the hasher.
    internal func hash(into hasher: inout Hasher) {
        var bytes = name
        bytes.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}
