/// The user's answer when an item could not be copied or deleted.
public enum SyncErrorAnswer: Sendable {
    /// The run stops.
    case cancel
    /// The item is tried again.
    case retry
    /// The item is left out.
    case skip
    /// The item and every other one that fails in this run are left out without asking.
    case skipAll
}
