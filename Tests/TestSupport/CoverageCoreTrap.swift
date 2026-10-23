import Darwin

/// For exit tests of a `preconditionFailure` or `fatalError`: the counts of a process that a trap ends.
///
/// A trap ends the process at once, and the coverage counts of a test run are written when a process exits. Called
/// at the start of an exit test's body, this has the trap end the process through `exit` instead, which writes the
/// counts (a build without coverage writes nothing) and ends it with a failure, as the trap would have.
public enum CoverageCoreTrap {
    /// From here on, a trap in this process ends it with exit status 1 and its counts written.
    public static func exitOnTrap() {
        // A trap is SIGTRAP on Apple silicon, SIGILL on Intel.
        for trap in [SIGTRAP, SIGILL] {
            _ = signal(trap) { _ in exit(1) }
        }
    }
}
