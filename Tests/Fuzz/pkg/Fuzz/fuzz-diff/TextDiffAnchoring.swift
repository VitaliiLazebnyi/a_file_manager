/// The cost limit and the anchors a `textdiff` input asks for.
internal struct TextDiffAnchoring {
    /// The cost limit handed to the diff; `nil` for none.
    internal let limit: Int?
    /// Pairs of lines the user tied together (left, right), possibly out of range.
    internal let anchors: [(left: Int, right: Int)]
}
