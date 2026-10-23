import AFMKernel
import Foundation

/// Runs `body` with a flag that is set as soon as either of two is: the session's own (set
/// by Disconnect) and the caller's (Cancel in the progress window).
///
/// Without a caller's flag the session's own is passed as it is.
internal func withEither<Result>(
    _ own: CancellationFlag,
    _ callers: CancellationFlag?,
    _ body: (CancellationFlag) throws -> Result
) rethrows -> Result {
    guard let callers, callers !== own else {
        return try body(own)
    }
    let both = CancellationFlag()
    // The registrations are released when the call is over; `both` outlives them.
    let registrations = [own.onCancel { both.cancel() }, callers.onCancel { both.cancel() }]
    defer {
        withExtendedLifetime(registrations) {
            // Only keeps the registrations until here.
        }
    }
    return try body(both)
}

/// A lock that is waited for in short turns, so the wait can end: when `cancellation` is set,
/// when `shouldGiveUp` says so (it returns the error to throw), and at once on the main thread,
/// which must never wait behind a login that may be asking the user something (the question is
/// answered on the main thread).
internal func lockPatiently(_ lock: NSLock, cancellation: CancellationFlag?, shouldGiveUp: () -> any Error?) throws {
    if lock.try() {
        return
    }
    if Thread.isMainThread { throw NetworkError.busy("The connection is busy logging in.") }
    while !lock.lock(before: Date().addingTimeInterval(0.1)) {
        if cancellation?.isCancelled == true { throw NetworkError.cancelled }
        if let error = shouldGiveUp() { throw error }
    }
}
