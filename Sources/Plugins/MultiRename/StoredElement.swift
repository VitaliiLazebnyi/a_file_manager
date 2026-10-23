/// One element of a stored list, read on its own: an element that cannot be read (damaged, or
/// written by another version) is nil, and the elements around it are kept.
internal struct StoredElement<Value: Decodable>: Decodable {
    /// The element; nil when it could not be read.
    internal let value: Value?

    /// Reads the element; never throws, a damaged element is nil.
    internal init(from decoder: any Decoder) {
        value = try? Value(from: decoder)
    }
}
