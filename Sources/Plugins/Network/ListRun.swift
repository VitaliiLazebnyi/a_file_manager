import AFMContracts
import AFMKernel
import Foundation

/// One run through a download list.
///
/// The copy jobs are asynchronous, so the run moves from line to line in their completions. Main
/// thread only; it keeps itself alive until the end.
@MainActor
internal final class ListRun {
    /// What is still to be done.
    private var items: ArraySlice<ListPlan.Item>
    /// The kernel whose jobs, panels and questions the run uses.
    private let kernel: Kernel
    /// The copy jobs of the program.
    private let transfers: any FileTransferService
    /// The lines not carried out, the plan's and those that failed on the way; shown at the end.
    private var skipped: [String]
    /// A completion that comes back at once does not call into the next line from inside
    /// this one: with many lines that would be a call inside a call for each of them.
    private var isStepping = false
    /// Whether `next()` was called while a line was being started, so the loop takes another.
    private var stepsAgain = false

    /// A run of `plan` with the copy jobs of `transfers`; nothing is done before `next()`.
    internal init(plan: ListPlan, kernel: Kernel, transfers: any FileTransferService) {
        items = ArraySlice(plan.items)
        skipped = plan.skipped
        self.kernel = kernel
        self.transfers = transfers
    }

    /// Starts the next line; at the end, tells which lines were not carried out.
    internal func next() {
        if isStepping {
            stepsAgain = true
            return
        }
        isStepping = true
        repeat {
            stepsAgain = false
            step()
        } while stepsAgain
        isStepping = false
    }

    /// Starts one line, or ends the run.
    private func step() {
        guard let item = items.popFirst() else {
            if !skipped.isEmpty {
                kernel.interaction.inform(
                    "Some lines of the download list were not carried out.",
                    detail: ListPlan.shortened(skipped),
                    style: .warning
                )
            }
            return
        }
        switch item {
        case .pause(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.next() }

        case .transfer(let step):
            let (source, destination) = (step.source, step.destination)
            let directory = destination.deletingLastPathComponent()
            // The usual copy job, with its usual question when the name is taken in the folder.
            transfers.transfer(
                step.kind == .move ? .move : .copy,
                [source],
                into: directory,
                renamingSelfCopies: false
            ) { [self] arrived in
                // The list may name the file differently at its destination.
                guard let arrived, arrived.lastPathComponent != destination.lastPathComponent else {
                    return next()
                }
                rename(arrived, to: destination, replacing: false)
            }
        }
    }

    /// Gives the file that arrived the name the list wants.
    ///
    /// A file that has that name already is replaced only when the user says so; otherwise the new
    /// file keeps the name it came with.
    private func rename(_ arrived: URL, to destination: URL, replacing: Bool) {
        let fileSystems = kernel.fileSystems
        kernel.jobs.run(
            title: "Renaming:",
            work: { _ -> (any Error)? in
                do {
                    try fileSystems.provider(for: arrived).move(arrived, to: destination, replacing: replacing)
                    return nil
                } catch {
                    return error
                }
            },
            completion: { [self] failure in
                if let failure, case FileSystemError.alreadyExists = failure, !replacing {
                    let question = "\(fileSystems.displayPath(destination)) already exists."
                    let detail =
                        "The download list wants the file that arrived as \(arrived.lastPathComponent) to have "
                        + "this name. Replace the existing file?"
                    if kernel.interaction.choose(
                        question,
                        detail: detail,
                        buttons: ["Replace", "Keep Both"],
                        style: .warning
                    )
                        == 0
                    {
                        return rename(arrived, to: destination, replacing: true)
                    }
                    skipped.append(
                        "\(fileSystems.displayPath(destination)) exists and was kept; the new file is "
                            + arrived.lastPathComponent
                    )
                } else if let failure {
                    skipped.append("\(fileSystems.displayPath(destination)): \(failure.localizedDescription)")
                }
                kernel.panels.refresh(
                    [destination.deletingLastPathComponent()],
                    focus: failure == nil ? destination : arrived
                )
                next()
            }
        )
    }

    deinit {
        // Nothing to release.
    }
}
