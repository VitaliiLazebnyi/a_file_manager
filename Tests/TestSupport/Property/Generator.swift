/// Makes random values of one kind from `Choices`, for property tests (`Property.check`).
///
/// A generator needs no shrinking of its own: a failing value is made smaller by replaying
/// smaller choices (see `Choices`), so a generator made with `map` or `flatMap` shrinks as well
/// as the ones it is made of.
public struct Generator<Value>: Sendable {
    /// Makes one value.
    private let make: @Sendable (inout Choices) -> Value

    /// A generator from a function that makes a value.
    @preconcurrency
    public init(_ make: @escaping @Sendable (inout Choices) -> Value) {
        self.make = make
    }

    /// One value, made from the choices.
    public func value(_ choices: inout Choices) -> Value {
        make(&choices)
    }

    /// The values turned into others.
    @preconcurrency
    public func map<Other>(_ transform: @escaping @Sendable (Value) -> Other) -> Generator<Other> {
        Generator<Other> { choices in transform(make(&choices)) }
    }

    /// A generator that depends on a value of this one.
    @preconcurrency
    public func flatMap<Other>(_ next: @escaping @Sendable (Value) -> Generator<Other>) -> Generator<Other> {
        Generator<Other> { choices in next(make(&choices)).value(&choices) }
    }

    /// Lists of values, with a length in `lengths`; shorter lists shrink first.
    public func array(_ lengths: ClosedRange<Int> = 0...20) -> Generator<[Value]> {
        Generator<[Value]> { choices in
            let count = lengths.lowerBound + Int(choices.next(below: UInt64(lengths.count)))
            return (0..<count).map { _ in make(&choices) }
        }
    }
}
