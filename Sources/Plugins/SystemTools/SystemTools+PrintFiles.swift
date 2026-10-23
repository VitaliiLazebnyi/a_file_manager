import AFMKernel
import Foundation

/// Printing the contents of files (spec 12 › Printing, File contents).
extension SystemTools {
    /// Files › Print › File contents (spec 12 › Printing): sends the files to the default
    /// printer through the system's print service, which knows text, PDF and pictures.
    internal func printFiles(_ operands: PanelModel.Operands) {
        // A few files are picked out here; the marked files of a long list in a job.
        guard operands.markedCount > Self.backgroundSelectionThreshold else {
            printFiles(operands.items().filter { !$0.isDirectory })
            return
        }
        kernel.jobs.run(
            title: "Reading file list:",
            work: { _ in operands.items().filter { !$0.isDirectory } },
            completion: { [self] files in printFiles(files) }
        )
    }

    /// Asks, then prints `files` in a job; `files` are never empty: the command is offered only
    /// with a file among the operands.
    internal func printFiles(_ files: [FileItem]) {
        let what = files.count == 1 ? DisplayText.oneLine(files[0].name, limit: 200) : "\(files.count) files"
        guard
            interaction.choose(
                "Print",
                detail: "Print \(what) on the default printer?",
                buttons: ["Print", "Cancel"],
                style: .information
            ) == 0
        else { return }
        // The log says how many when they are many: a line per file would be megabytes.
        let logged =
            "print-file: "
            + (files.count <= 8
                ? files.map { DisplayText.oneLine($0.name, limit: 200) }.joined(separator: ", ")
                : "\(files.count) files")
        let (printer, paths) = (desktop.printer, files.map(\.url.path))
        kernel.jobs.run(
            title: "Printing:",
            work: { monitor in
                // A few hundred files at a time: the system starts no program with more than 4,096 arguments (it
                // raises an exception instead), and their length is limited too. The first failure stops.
                var outcome = ProcessOutcome()
                for start in stride(from: 0, to: paths.count, by: Self.filesPerPrint)
                where outcome.failure == nil && outcome.status == 0 {
                    let part = Array(paths[start..<min(start + Self.filesPerPrint, paths.count)])
                    outcome = ProcessRunner(executable: printer, arguments: part, directory: nil)
                        .run(cancellation: monitor.cancellation, progress: nil)
                }
                return outcome
            },
            completion: { [self] outcome in
                if outcome.failure != nil || outcome.status != 0 {
                    return interaction.inform(
                        "\(what) cannot be printed!",
                        detail: outcome.failure ?? outcome.output,
                        style: .warning
                    )
                }
                note(logged)
            }
        )
    }
}
