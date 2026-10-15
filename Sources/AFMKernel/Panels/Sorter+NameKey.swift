/// Keys of names for comparing them many times.
extension Sorter {
    /// The key of a name for `compare(_:_:numeric:)` (see `Sorter.key(of:numeric:)`): two
    /// names are in the order of their keys.
    public struct NameKey: Comparable, Sendable {
        /// The collation key of the name.
        internal let key: [UInt8]
        /// The name, which decides between equal keys.
        internal let name: String

        /// Whether two keys are of the same name, byte for byte.
        public static func == (lhs: Self, rhs: Self) -> Bool { ExactName.areSame(lhs.name, rhs.name) }

        /// Whether the first name comes before the second.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            if ExactName.areSame(lhs.name, rhs.name) {
                return false
            }
            var result = lhs.key.withUnsafeBufferPointer { first in
                rhs.key.withUnsafeBufferPointer { SortKeys.bytewise(first, $0) }
            }
            if result == 0 { result = SortKeys.bytewise(lhs.name, rhs.name) }
            return result < 0
        }
    }
}
