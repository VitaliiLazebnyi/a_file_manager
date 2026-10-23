/// The user's answer when a copy would replace an existing file.
public enum SyncOverwriteAnswer: Sendable {
    /// The run stops.
    case cancel
    /// This file is replaced.
    case overwrite
    /// This file and every other one of the run are replaced without asking.
    case overwriteAll
    /// This file is left as it is.
    case skip
    /// This file and every other existing one of the run are left as they are.
    case skipAll
}
