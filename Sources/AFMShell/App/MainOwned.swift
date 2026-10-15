/// Something that belongs to the main thread, carried through a background thread.
///
/// It is put in and taken out on the main thread, so it is also let go of there, whichever
/// thread drops the box last. Closures that hold a panel or a model travel this way.
///
/// Unchecked: the value is put in by `init`, before the box is shared, and taken out on the
/// main thread only. `held` is read on the main thread, or by a thread that was started after
/// the box was filled and whose result alone makes the main thread take the value out
/// (`ProgressJobService.run`).
internal final class MainOwned<Value>: @unchecked Sendable {
    /// The value, until it is taken out.
    private var value: Value?

    /// The value, which stays in the box; main thread.
    internal var held: Value? { value }

    /// A box holding `value`.
    internal init(_ value: Value) {
        self.value = value
    }

    /// The value, which leaves the box; main thread.
    internal func take() -> Value? {
        defer { value = nil }
        return value
    }

    deinit {
        // The value goes with the box.
    }
}
