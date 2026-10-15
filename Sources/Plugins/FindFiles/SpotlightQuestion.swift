/// A question to Spotlight as the Find Files window asks it: a `SpotlightSearch`, or what a test
/// puts in its place to answer when it likes.
internal protocol SpotlightQuestion: AnyObject {
    /// The most paths read out of the answer.
    var limit: Int { get }

    /// Asks; `completion` gets the paths and whether the answer was cut at `limit`, on the main thread.
    func start(completion: @escaping @MainActor @Sendable ([String], Bool) -> Void)

    /// Ends the question without an answer.
    func stop()
}
