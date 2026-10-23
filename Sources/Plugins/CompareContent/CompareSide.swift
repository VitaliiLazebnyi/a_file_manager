/// One of the two files of a comparison.
internal enum CompareSide {
    /// The first file, shown on the left (or on top).
    case left
    /// The second file, shown on the right (or below).
    case right

    /// The side across from this one.
    internal var other: Self { self == .left ? .right : .left }
}
