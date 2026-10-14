import Foundation

/// States which thread a piece of state belongs to.
///
/// Panel state, the registries and everything on screen belong to the main thread; these checks stop a wrong caller in
/// debug builds.
public enum MainThread: Sendable {
    /// Stops a debug build when called off the main thread; `what` names the state in the message (`"The job
    /// service"`).
    ///
    /// Release builds check nothing.
    public static func assert(
        _ what: @autoclosure () -> String = "This",
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        Swift.assert(Thread.isMainThread, "\(what()) must be used on the main thread", file: file, line: line)
    }
}
