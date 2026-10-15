import Foundation

/// One element of a stored list, read on its own: an element that cannot be read (damaged, or
/// written by another version) is nil, and the elements around it are kept.
struct StoredElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) {
        value = try? Value(from: decoder)
    }
}
