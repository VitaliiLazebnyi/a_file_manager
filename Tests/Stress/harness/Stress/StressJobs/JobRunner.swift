import AFMKernel
import Foundation
import StressKit

@testable import AFMShell
@testable import FileOperationsPlugin

/// Runs jobs through the shell's real job service while a controller interferes.
@MainActor
internal enum JobRunner {
    /// The job service of the program, with its pause gate and its reports to the main thread.
    internal static let service = ProgressJobService()

    /// Runs the job `make` returns through the job service while another thread interferes.
    ///
    /// The controller's thread pauses, resumes and cancels it; the main run loop is pumped until the
    /// job's completion was called.
    internal static func run(_ plan: JobPlan, make: @escaping @Sendable (CancellationFlag) -> FileJob) -> Outcome {
        let finished = Shared<JobResult?>(nil)
        let recorderBox = Shared<Recorder?>(nil)
        let controller = Controller(interference: plan.interference, seed: plan.seed)
        let started = now()
        HangGuard.shared.arm(plan.label, seconds: plan.limit)
        let label = plan.label
        let configure = plan.configure
        service.run(
            title: label,
            work: { monitor -> JobResult in
                controller.jobFlag.value = monitor.cancellation
                let job = make(monitor.cancellation)
                let recorder = Recorder(monitor: monitor, label: label)
                recorderBox.value = recorder
                job.delegate = recorder
                job.progressInterval = 0.04
                configure?(job)
                return withExtendedLifetime(recorder) { job.run() }
            },
            completion: { result in
                finished.value = result
            }
        )
        controller.start()

        pump(upTo: plan.limit + 30) { finished.value != nil }
        controller.stop.cancel()
        HangGuard.shared.disarm()
        var outcome = Outcome()
        outcome.result = finished.value ?? JobResult()
        outcome.wall = now() - started
        outcome.pauses = controller.pauses.value
        outcome.cancelSent = controller.cancelSent.value
        if let recorder = recorderBox.value {
            outcome.reports = recorder.reports
            outcome.errors = recorder.errors
            outcome.last = recorder.lastProgress
        }
        if service.isBusy {
            Findings.shared.violation("job service still busy after completion", label)
        }
        return outcome
    }
}
