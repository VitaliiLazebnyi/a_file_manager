@testable import FindFilesPlugin

/// A question to Spotlight that answers when the test says, also after it was stopped, as an
/// answer that was already on its way does.
///
/// Used on the main thread only.
internal final class StabilityFindSpotlight: SpotlightQuestion {
    /// The most paths read out of the answer.
    internal let limit = 10
    /// What the window is to be told; nil before it asked and once it was told.
    internal private(set) var completion: (@MainActor @Sendable ([String], Bool) -> Void)?
    /// Whether the window stopped the question.
    internal private(set) var isStopped = false

    /// Keeps `completion` until the test answers.
    internal func start(completion: @escaping @MainActor @Sendable ([String], Bool) -> Void) {
        self.completion = completion
    }

    /// Notes the stop; an answer may still be on its way.
    internal func stop() { isStopped = true }

    /// Tells the window `paths`, as Spotlight's answer does.
    @MainActor
    internal func answer(_ paths: [String]) {
        // Told once, and let go of, as Spotlight's own answer is.
        let told = completion
        completion = nil
        told?(paths, false)
    }

    deinit {
        // Nothing to release.
    }
}
