/// Stands for what questions are asked of in `BlockingCalls`, which counts them by their owner:
/// only its identity is used.
internal final class CallOwner: Sendable {
    deinit {
        // Nothing to release.
    }
}
