import AFMContracts
import AFMKernel
import Foundation

/// The File menu: open another file, save what is shown under another name, edit it.
extension ViewerPane {
    /// The work of Save as: `source` written to `target`, with its progress; the error, unless
    /// the user stopped it.
    nonisolated internal static func save(
        _ source: any ByteSource,
        to target: URL,
        monitor: any JobMonitor
    ) -> (any Error)? {
        do {
            try ViewerSave.save(source, to: target, cancellation: monitor.cancellation) { offset in
                monitor.report(
                    JobProgress(
                        lines: ["To: \(target.path)"],
                        itemsDone: 0,
                        itemsTotal: 1,
                        bytesDone: offset,
                        bytesTotal: source.length
                    )
                )
            }
            return nil
        } catch {
            return monitor.cancellation.isCancelled ? nil : error
        }
    }

    /// File › Open: another file, chosen in the open panel, in this pane.
    internal func openFile() {
        guard let url = dialogs.fileToOpen() else {
            return
        }
        load(ViewerItem(source: .file(url), title: kernel.fileSystems.displayPath(url)))
    }

    /// Saves what is shown under another name: meant for files that came out of an archive or
    /// from a server (spec 10 › File menu behaviour).
    ///
    /// Runs as a job with a progress window.
    internal func saveAs() {
        guard let loaded else {
            return
        }
        guard let target = dialogs.saveTarget(proposing: loaded.item.url?.lastPathComponent ?? loaded.item.title)
        else { return }
        // The file that is shown is read while the copy is written: it is not replaced.
        guard !ViewerSave.isSameFile(loaded.item.url, target) else {
            kernel.interaction.inform(
                "The file is being shown from the place you chose. Choose another file name or folder."
            )
            return
        }
        let source = loaded.source
        kernel.jobs.run(
            title: "Save as",
            work: { monitor in Self.save(source, to: target, monitor: monitor) },
            completion: { [weak self] error in
                if let error { self?.kernel.interaction.report(error, title: "Save as") }
                self?.kernel.panels.refresh([target.deletingLastPathComponent()])
            }
        )
    }

    /// F4: the file in the editor.
    internal func edit() {
        guard let url = item?.url else {
            return
        }
        kernel.commands.perform(.edit, .location(url))
    }
}
