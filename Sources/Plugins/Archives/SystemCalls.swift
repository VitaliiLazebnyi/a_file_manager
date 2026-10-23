import Foundation

/// Makes a system call that reads or writes, again for as long as a signal interrupts it
/// (`EINTR`); the count it returns, or -1 with `errno` set.
internal func retryingInterrupted(_ call: () -> Int) -> Int {
    var result: Int
    repeat {
        result = call()
    } while result < 0 && errno == EINTR
    return result
}

/// The error a failed system call reports: the system's text for `code`, followed by the `path` it was about.
internal func posixError(_ code: Int32, _ path: String) -> any Error {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code)) + ": " + path]
    )
}
