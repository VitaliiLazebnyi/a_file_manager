/// An array read element by element: an element that cannot be decoded is counted in the
/// running `DecodeReport` and skipped, the rest is kept.
internal struct LenientElements<Element: Decodable>: Decodable {
    /// Reads past one element whatever it holds.
    private struct Ignored: Decodable {
        /// Takes the element without reading anything from it.
        init(from _: any Decoder) {
            // Nothing to read: the element is only stepped over.
        }
    }

    /// The elements that could be decoded, in stored order.
    internal var elements: [Element] = []

    /// Reads the array under `decoder`, skipping and counting every element that cannot be decoded.
    ///
    /// Throws only when the stored value is not an array at all.
    internal init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                DecodeReport.current?.skipped += 1
                _ = try container.decode(Ignored.self)
            }
        }
    }
}
