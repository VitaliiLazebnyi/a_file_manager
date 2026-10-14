/// A value for which a property did not hold, made as small as shrinking could make it.
public struct Counterexample<Value>: CustomStringConvertible {
    /// The smallest failing value found.
    public let value: Value
    /// The value as it was first found, before shrinking.
    public let original: Value
    /// The seed of the run that found it: `AFM_PROPERTY_SEED=<seed>` makes the run again.
    public let seed: UInt64
    /// How many values held before this one failed.
    public let passed: Int

    /// What a test reports.
    public var description: String {
        "property fails for \(String(reflecting: value)) (found as \(String(reflecting: original)) "
            + "after \(passed) passing values; AFM_PROPERTY_SEED=\(seed) repeats the run)"
    }
}
