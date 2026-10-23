/// A counter written into the placeholder itself: `[C10+5:3]`, `[C+1/100]`, `[Caa+1]`
/// (spec 18 › Counter).
///
/// It ignores the Define-counter fields.
internal struct InlineCounter: Equatable {
    /// The number of the first item.
    internal var start = 1
    /// The start of an alphabetic counter (`aa`); its length is the width.
    internal var letters: String?
    /// What each further step adds.
    internal var step = 1
    /// The counter moves on only every so many items.
    internal var divisor = 1
    /// nil is the automatic width `a`.
    internal var digits: Int? = 1
}
