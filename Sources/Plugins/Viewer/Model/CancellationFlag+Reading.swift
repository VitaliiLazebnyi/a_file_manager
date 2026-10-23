import AFMKernel
import Foundation

/// How the viewer's reads end when their flag is set.
extension CancellationFlag {
    /// What a read that was ended by its flag throws; whoever set the flag does not look at it.
    internal func throwIfCancelled() throws {
        if isCancelled { throw CocoaError(.userCancelled) }
    }

    /// Runs `body` with `reader` interrupted should the flag be set meanwhile.
    internal func whileReading<T>(_ reader: any FileReader, _ body: () throws -> T) rethrows -> T {
        let token = interrupting(reader)
        defer {
            withExtendedLifetime(token) {
                // The interruption is unhooked only here, once `body` is done.
            }
        }
        return try body()
    }
}
