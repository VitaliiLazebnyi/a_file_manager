import AFMKernel

@testable import AFMShell

/// A progress sheet without a job service, for the tests that ask through it.
extension ProgressSheet {
    /// The progress of a job `title` with an open gate and no window.
    internal convenience init(title: String, cancellation: CancellationFlag) {
        self.init(title: title, cancellation: cancellation, gate: PauseGate(), display: nil)
    }
}
