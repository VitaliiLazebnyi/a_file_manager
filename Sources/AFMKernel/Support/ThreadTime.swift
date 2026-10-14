public import Foundation

/// The processor time a thread has used, for a limit on how much **work** something may take.
/// Such a limit must not be measured by the clock: on a machine where more threads want to
/// run than there are cores, a thread stands still for long stretches, and a search that
/// allows a regular expression a quarter of a second "of time" then gives up on names it
/// would have matched in a millisecond. The answer would depend on how busy the machine is.
public enum ThreadTime: Sendable {
    /// Seconds of processor time the calling thread has used so far.
    public static var used: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
    }
}
