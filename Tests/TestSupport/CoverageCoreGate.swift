import Foundation

/// Something a test holds shut until it lets it go: whoever passes waits until then, on any thread.
///
/// Unchecked: `isOpen` is guarded by `condition`.
public final class CoverageCoreGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    /// Shut.
    public init() {
        // Shut until `open`.
    }

    /// Waits until the gate is open.
    public func pass() {
        condition.lock()
        while !isOpen { condition.wait() }
        condition.unlock()
    }

    /// Lets everybody through, now and from now on.
    public func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    deinit {
        // Nothing to release.
    }
}
