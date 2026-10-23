/// A stored list read element by element: an element that cannot be decoded is counted and
/// skipped, so one bad entry (or a field a later version added) does not take the rest along.
internal struct LenientList<Element: Decodable>: Decodable {
    /// Any value, read only to step over it.
    private struct Ignored: Decodable {
        init(from _: any Decoder) {
            // Nothing is kept of a value that is skipped.
        }
    }

    /// The elements that could be read, in their order.
    internal var elements: [Element] = []
    /// How many elements could not be read and were left out.
    internal var skipped = 0

    /// Reads the list; throws only when the data is not a list.
    internal init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                skipped += 1
                _ = try container.decode(Ignored.self)
            }
        }
    }
}
