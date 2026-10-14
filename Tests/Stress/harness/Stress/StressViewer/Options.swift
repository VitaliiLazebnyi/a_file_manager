import Foundation

/// What the environment turns off or on, for looking at one part of the scenario alone.
internal enum Options {
    /// STRESS_NO_HAMMER: no reader or searcher threads.
    internal static let noHammer = ProcessInfo.processInfo.environment["STRESS_NO_HAMMER"] != nil
    /// STRESS_NO_USER: nobody scrolls the pager.
    internal static let noUser = ProcessInfo.processInfo.environment["STRESS_NO_USER"] != nil
    /// STRESS_NO_SEARCHERS: reader threads, but no searcher threads.
    internal static let noSearchers = ProcessInfo.processInfo.environment["STRESS_NO_SEARCHERS"] != nil
    /// STRESS_HOLD: seconds to stay alive after the scenario, to look at the process.
    internal static let hold = ProcessInfo.processInfo.environment["STRESS_HOLD"].flatMap(Double.init)
}
