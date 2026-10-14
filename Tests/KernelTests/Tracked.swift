import TestSupport

/// An object that counts its instances that are still alive, for checking that work let go of
/// what it made.
internal final class Tracked {
    /// The number of instances alive, from any thread.
    private static let alive = Shared(0)

    /// How many instances are alive now.
    internal static var count: Int { alive.value }

    /// Counts one more.
    internal init() {
        Self.alive.modify { $0 += 1 }
    }

    deinit {
        Self.alive.modify { $0 -= 1 }
    }
}
