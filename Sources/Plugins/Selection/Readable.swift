/// One element of a saved list, nil when it does not read (written by another version, or
/// edited by hand): decoding the list as `[Readable<Element>]` keeps the elements that read.
internal struct Readable<Element: Decodable>: Decodable {
    /// The element, or nil when it did not read.
    internal let value: Element?

    /// Reads the element; a failure leaves it nil instead of failing the whole list.
    internal init(from decoder: any Decoder) {
        value = try? Element(from: decoder)
    }
}
