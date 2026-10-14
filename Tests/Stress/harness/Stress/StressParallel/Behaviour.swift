/// What the leaves of a nested tree do besides computing their value.
internal struct Behaviour: Sendable {
    /// Some leaves sleep up to 3.5 ms.
    internal var sleeps = true
    /// Some leaves call `stat`.
    internal var callsStat = true
    /// Some leaves on helper threads hop to the main thread with `DispatchQueue.main.sync`.
    internal var mainSync = false
}
