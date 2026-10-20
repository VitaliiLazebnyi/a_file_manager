import Network
import TestSupport

@testable import NetworkPlugin

/// A framer that is ready at once, schedules one wakeup, and hands Network's calls on to an
/// `FTPAuthTLSFramer`; it reads nothing.
internal final class ForwardingFramer: NWProtocolFramerImplementation {
    /// The framer's name in Network.
    internal static let label = "afm-test-forwarding"
    /// What a connection's options name to use this framer.
    internal static let definition = NWProtocolFramer.Definition(implementation: ForwardingFramer.self)
    /// The option that holds the `Signal<Bool>` the wakeup sets.
    internal static let wokenKey = "woken"

    /// The framer under test.
    private let inner: FTPAuthTLSFramer

    /// Made by Network for each connection, with the framer under test.
    internal init(framer: NWProtocolFramer.Instance) {
        inner = FTPAuthTLSFramer(framer: framer)
    }

    /// Ready at once (the framer under test waits for TLS), with a wakeup asked for.
    internal func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        framer.scheduleWakeup(wakeupTime: .milliseconds(0))
        return .ready
    }

    /// Handed on; the test hears of it.
    internal func wakeup(framer: NWProtocolFramer.Instance) {
        inner.wakeup(framer: framer)
        (framer.options[Self.wokenKey] as? Signal<Bool>)?.set(true)
    }

    /// Handed on.
    internal func stop(framer: NWProtocolFramer.Instance) -> Bool {
        inner.stop(framer: framer)
    }

    /// Handed on.
    internal func cleanup(framer: NWProtocolFramer.Instance) {
        inner.cleanup(framer: framer)
    }

    /// Handed on: what the connection sends.
    internal func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        inner.handleOutput(framer: framer, message: message, messageLength: messageLength, isComplete: isComplete)
    }

    /// Nothing is read: the test sends only.
    internal func handleInput(framer _: NWProtocolFramer.Instance) -> Int {
        0
    }

    deinit {
        // Nothing to release.
    }
}
