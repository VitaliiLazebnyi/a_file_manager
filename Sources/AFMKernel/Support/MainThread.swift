import Foundation

/// States which thread a piece of state belongs to. Panel state, the registries and everything
/// on screen belong to the main thread; these checks stop a wrong caller in debug builds.
public enum MainThread: Sendable {
    public static func assert(
        _ what: @autoclosure () -> String = "This",
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        Swift.assert(Thread.isMainThread, "\(what()) must be used on the main thread", file: file, line: line)
    }
}
