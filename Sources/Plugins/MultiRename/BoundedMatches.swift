/// What a search with a bound on its time found.
internal enum BoundedMatches<Match: Equatable>: Equatable {
    /// The search got to the end: these are its matches (all of them, or the first).
    case found([Match])
    /// The search took too long or was cancelled: nothing is known.
    case gaveUp
}
