/// The figures of one kind of call the hammer threads make.
internal struct OpStats {
    /// How many calls.
    internal var count = 0
    /// Their seconds together.
    internal var total = 0.0
    /// The longest, in milliseconds.
    internal var maxMs = 0.0
    /// How many had their flag set by the time they returned.
    internal var cancelled = 0
    /// How many threw.
    internal var threw = 0
}
