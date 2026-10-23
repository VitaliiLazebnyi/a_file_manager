/// What a change does to one flag of an item: hidden or locked (spec 07 › Change attributes).
///
/// The raw value is the item's place in the dialog's list: Unchanged, Set, Clear.
internal enum FlagChange: Int, Equatable {
    /// Clears the flag.
    case clear = 2
    /// Leaves the flag as the item has it.
    case keep = 0
    /// Sets the flag.
    case set = 1

    /// The change the dialog's choice at `index` stands for; no choice at all (-1) keeps the flag.
    internal init(choice index: Int) {
        switch index {
        case 1:
            self = .set

        case 2:
            self = .clear

        default:
            self = .keep
        }
    }
}
