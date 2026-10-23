import AFMContracts
import AFMKernel
import Foundation

/// The details lines of the operands on their way to a file, through the file's own file
/// system (spec 03 › Selection files, `cm_SaveDetailsToFile`).
///
/// A value with everything read on the main thread beforehand; the lines are made and written
/// in a job. An existing file is replaced only after a question.
internal struct DetailsFile {
    /// The file to write.
    internal let url: URL
    /// The items whose lines are written.
    internal let operands: PanelModel.Operands
    /// The plugin columns the panel shows, after the standard ones.
    internal let extra: [NameList.Column]
    /// Whether a line of column titles comes first.
    internal let headers: Bool
    /// Writes the lines, and the locations as the kernel's file systems do.
    internal let list: NameList

    /// Writes the file in a job; main thread.
    ///
    /// A failure is reported to the user; after a write the folder is read again with the cursor
    /// on the new file.
    @MainActor
    internal func save(in kernel: Kernel) {
        let (fileSystems, interaction) = (kernel.fileSystems, kernel.interaction)
        kernel.jobs.run(
            title: "Saving details:",
            work: { [self] monitor -> (any Error)? in
                do {
                    try write(fileSystems: fileSystems, interaction: interaction, monitor: monitor)
                    return nil
                } catch {
                    return error
                }
            },
            completion: { error in
                // Declining to overwrite is no failure and changes nothing.
                if (error as? CocoaError)?.code == .userCancelled {
                    return
                }
                if let error { kernel.interaction.report(error, title: "The details cannot be saved!") }
                kernel.panels.refresh([url.deletingLastPathComponent()], focus: error == nil ? url : nil)
            }
        )
    }

    /// Writes the lines next to the target and moves them into place when complete: a failed write
    /// leaves the old file as it was, and nothing is removed before there is a new one.
    ///
    /// On the job's thread. Throws `CocoaError(.userCancelled)` when the job was cancelled or the
    /// user kept the file that is there, else what the file system threw.
    private func write(fileSystems: FileSystemRegistry, interaction: any UserInteraction, monitor: any JobMonitor)
        throws
    {
        let provider = try fileSystems.provider(for: url)
        let cancellation = monitor.cancellation
        let existing = provider.item(at: url, cancellation: cancellation)
        if cancellation.isCancelled {
            throw CocoaError(.userCancelled)
        }
        if let existing {
            // Only a file is replaced; a folder of that name is not this command's to remove.
            if existing.isDirectory { throw FileSystemError.alreadyExists(fileSystems.displayPath(url)) }
            // Return keeps the file that is there.
            // `@Sendable`, so that it may be sent from this thread to the main thread.
            let replace = monitor.ask { @Sendable in
                interaction.choose(
                    "Overwrite:",
                    detail: Format.displayName(fileSystems.displayPath(url)),
                    buttons: ["Overwrite", "Cancel"],
                    style: .warning,
                    defaultButton: 1
                ) == 0
            }
            guard replace else {
                throw CocoaError(.userCancelled)
            }
        }
        let text = list.details(operands.items(), .name, headers: headers, extra: extra, mask: nil)
        do {
            try DraftWrite.write(
                Data(text.utf8),
                to: url,
                replacing: existing != nil,
                through: provider,
                cancellation: cancellation
            )
        } catch {
            throw cancellation.isCancelled ? CocoaError(.userCancelled) : error
        }
    }
}
