import AFMContracts
import AFMKernel
import Foundation

/// The download list: adding the marked files to it, and working through it.
extension NetworkCommands {
    /// Adds a line for each of `items` to the list file; returns how many could not be written as a line.
    ///
    /// Each line names the place in `targetDirectory` the file is to go to, when that folder is on
    /// this Mac. In a job. Throws when the list cannot be read or written, would grow too large, or the
    /// job is cancelled.
    nonisolated private static func add(
        _ items: [FileItem],
        to list: URL,
        into targetDirectory: URL,
        fileSystems: FileSystemRegistry,
        monitor: any JobMonitor
    ) throws -> Int {
        var text = FileManager.default.fileExists(atPath: list.path) ? try readList(list) : ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        var refused = 0
        for item in items {
            if monitor.cancellation.isCancelled { throw NetworkError.cancelled }
            let source = fileSystems.displayPath(item.url)
            let target = targetDirectory.isFileURL ? targetDirectory.appending(name: item.name).path : nil
            // A name with a line break would be read back as a line of its own, with whatever it says.
            guard DownloadList.canHold(source: source, target: target) else {
                refused += 1
                continue
            }
            text += DownloadList.line(source: source, target: target) + "\n"
        }
        guard text.utf8.count <= DownloadList.largestFile else {
            throw VolumeError(
                message: "The download list would become larger than \(DownloadList.largestFile >> 20) MB."
            )
        }
        try text.write(to: list, atomically: true, encoding: .utf8)
        return refused
    }

    /// Asks for the list file, proposing the one named last; nil on Cancel or for a location that
    /// is not on this Mac.
    private func askForList(_ title: String) -> URL? {
        let proposal = kernel.settings.text(
            NetworkSettings.listName,
            default: "~/Downloads/" + DownloadList.defaultName
        )
        guard let text = interaction.prompt(title, value: proposal)?.trimmingCharacters(in: .whitespaces),
            !text.isEmpty
        else {
            return nil
        }
        kernel.settings.set(text, forKey: NetworkSettings.listName)
        let location = kernel.fileSystems.location(
            from: text,
            relativeTo: source.model.directory.isFileURL
                ? source.model.directory
                : FileManager.default.homeDirectoryForCurrentUser
        )
        return location.isFileURL ? location : nil
    }

    /// Download later: writes the marked files of the server into the list file, each with
    /// the place it is to go to (spec 11 › Download later).
    ///
    /// The lines are made in the job, not here: with very many files that is work the main thread
    /// must not do.
    internal func addToDownloadList() {
        let items = source.model.operands()
        guard !items.isEmpty, let list = askForList("File name of download list:") else {
            return
        }
        let fileSystems = kernel.fileSystems
        let targetDirectory = kernel.panels.target.model.directory
        kernel.jobs.run(
            title: "Download list:",
            work: { monitor -> Result<Int, any Error> in
                Result {
                    try Self.add(items, to: list, into: targetDirectory, fileSystems: fileSystems, monitor: monitor)
                }
            },
            completion: { [kernel] result in
                switch result {
                case .failure(NetworkError.cancelled):
                    break

                case .failure(let error):
                    kernel.interaction.report(error, title: "The download list cannot be written!")

                case .success(let refused) where refused > 0:
                    kernel.interaction.inform(
                        "\(refused) of the files were not added to the download list.",
                        detail: "Their names contain a line break or the list's separator, which a list cannot hold.",
                        style: .warning
                    )

                case .success:
                    break
                }
                kernel.panels.refresh([list.deletingLastPathComponent()])
            }
        )
    }

    /// Works through a list file, one line after the other, with the usual copy job for each
    /// (spec 11 › Net › FTP Download From List…).
    ///
    /// Lines without a target go to the folder of the target panel.
    ///
    /// A list file may come from anybody and says what is copied where, so nothing runs
    /// before the user has seen what the list would do and agreed (`ListPlan.preview`).
    internal func downloadFromList() {
        guard let list = askForList("File name of download list:") else {
            return
        }
        guard let transfers = kernel.services.find((any FileTransferService).self) else {
            interaction.inform("Copying files is not available.", detail: "", style: .warning)
            return
        }
        let target = kernel.panels.target.model.directory
        let base = target.isFileURL ? target : FileManager.default.homeDirectoryForCurrentUser
        kernel.jobs.run(
            title: "Download list:",
            work: { _ in
                Result { try Self.readList(list) }
            },
            completion: { [kernel] result in
                let text: String
                switch result {
                case .success(let read):
                    text = read

                case .failure(let error):
                    return kernel.interaction.report(error, title: "The download list cannot be read!")
                }
                let plan = ListPlan(actions: DownloadList.parse(text), base: base, fileSystems: kernel.fileSystems)
                guard !plan.steps.isEmpty else {
                    return kernel.interaction.inform(
                        "The download list \(list.path) holds nothing that can be carried out.",
                        detail: ListPlan.shortened(plan.skipped),
                        style: .warning
                    )
                }
                let preview = plan.preview(of: list)
                guard
                    kernel.interaction.choose(
                        preview.message,
                        detail: preview.detail,
                        buttons: ["Run the List", "Cancel"],
                        style: plan.touchesLocalFiles ? .critical : .warning
                    ) == 0
                else { return }
                ListRun(plan: plan, kernel: kernel, transfers: transfers).next()
            }
        )
    }
}
