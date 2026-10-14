internal import FuzzC

// What a running target uses from the fuzzer: failing, checking, its work folder and a note for
// the statistics. The targets run on the main thread; so do these.

/// Where the running target may write; set for each worker and each `run`.
@MainActor public internal(set) var fzWorkDir = ""

/// Hands the worker a line for its statistics (for instance what the slowest input was).
@MainActor public var fzNote: (String) -> Void = { _ in
    // No worker listens: `run` and `min` keep no statistics.
}

/// A broken invariant: reported as a finding with `key` as its signature.
public func fzFail(_ key: String, _ detail: String = "") -> Never {
    fz_fail(key + "\n" + String(detail.prefix(4_000)))
}

/// Fails with `key` (and `detail`) unless `condition` holds.
public func fzCheck(_ condition: @autoclosure () -> Bool, _ key: String, _ detail: @autoclosure () -> String = "") {
    if !condition() {
        fzFail(key, detail())
    }
}
