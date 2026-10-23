/// The fields of "Define counter" (spec 09 › Define counter).
internal struct CounterDefinition: Codable, Equatable {
    /// The number of the first item.
    internal var start = 1
    /// What each further item adds.
    internal var step = 1
    /// The least number of digits; 0 stands for `a`, the width of the number of items.
    internal var digits = 1
}
