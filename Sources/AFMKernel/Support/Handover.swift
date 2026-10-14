/// A value handed from one thread to another that the compiler cannot prove safe to send, but
/// that is: the type is thread-safe without being marked so on every system the program runs
/// on (`NSImage` is `Sendable` only from macOS 14), or the sending side lets go of the value.
/// Every use says which.
public struct Handover<Value>: @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }
}
