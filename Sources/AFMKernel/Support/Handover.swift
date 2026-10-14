/// A value handed from one thread to another that the compiler cannot prove safe to send, but
/// that is: the type is thread-safe without being marked so, or the sending side lets go of
/// the value, or only one thread uses it at a time. Every use says which.
public struct Handover<Value>: @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }
}
