import Foundation
import os

/// States which thread a piece of state belongs to.
///
/// Panel state, the registries and everything on screen belong to the main thread; a caller on
/// another thread is a bug, which these checks log as a fault (`Log`, category `Kernel`) with the
/// place of the call.
public enum MainThread: Sendable {
    private static let log = Log.logger("Kernel")

    /// Logs a fault when called off the main thread.
    ///
    /// `what` names the state in the message (`"The job service"`). On the main thread it costs
    /// one look at the thread.
    public static func assert(
        _ what: @autoclosure () -> String = "This",
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard !Thread.isMainThread else {
            return
        }
        let name = what()
        log.fault("\(name, privacy: .public) must be used on the main thread (\(file, privacy: .public):\(line))")
    }
}
