import AFMContracts
import AFMKernel
import Foundation

/// New folder (F7) and new text file (Shift+F4): the names typed, read with their placeholders,
/// and the items made on a job's thread.
extension FileOperations {
    /// The names typed for new folders or files, and what is needed to make them on a job's thread.
    private struct NewItems: Sendable {
        /// The text as typed.
        let typed: String
        /// What the placeholders refer to, without the clipboard and the look at the file system.
        let context: NameTemplate.Context
        /// The folder the new items go to.
        let directory: URL
        /// The file systems the items are made on.
        let fileSystems: FileSystemRegistry
        /// The text of the clipboard, read only when a name asks for it.
        let clipboard: @Sendable () -> String?
        /// Where the records of the log go; nil while the log is off.
        let record: (@Sendable (OperationRecord) -> Void)?

        /// Whether something is at a location, asked so that the question ends with the job.
        func exists(_ url: URL, _ cancellation: CancellationFlag) -> Bool {
            (try? fileSystems.provider(for: url))?.item(at: url, cancellation: cancellation) != nil
        }

        /// The names the text gives; `quotedLists` also splits at quotes (new files).
        ///
        /// Throws `NameTemplate.Failure`.
        func names(quotedLists: Bool, _ cancellation: CancellationFlag) throws -> [String] {
            var filled = context
            filled.clipboard = typed.contains("[X") ? clipboard() : nil
            filled.exists = { [self] name in
                exists(fileSystems.location(from: name, relativeTo: directory), cancellation)
            }
            return try NameTemplate.names(from: typed, context: filled, quotedLists: quotedLists)
        }

        /// Makes the folders; returns the last one made and the names that failed, with their errors.
        func makeFolders(_ cancellation: CancellationFlag) -> (created: URL?, failures: [(String, any Error)]) {
            let names: [String]
            do {
                names = try self.names(quotedLists: false, cancellation)
            } catch {
                return (nil, [(typed, error)])
            }
            var created: URL?
            var failures: [(String, any Error)] = []
            for name in names where !cancellation.isCancelled {
                let url = fileSystems.location(from: name, relativeTo: directory)
                do {
                    if exists(url, cancellation) { throw FileSystemError.alreadyExists(fileSystems.displayPath(url)) }
                    // A folder that appeared since the look above is not taken for the new one.
                    try fileSystems.provider(for: url)
                        .createDirectory(at: url, exclusive: true, cancellation: cancellation)
                    created = url
                    record?(OperationRecord(.makeFolder, source: fileSystems.displayPath(url)))
                } catch {
                    if cancellation.isCancelled { break }
                    failures.append((name, error))
                    let status = OperationRecord.Status.failed(error.localizedDescription)
                    record?(OperationRecord(.makeFolder, source: fileSystems.displayPath(url), status: status))
                }
            }
            return (created, failures)
        }

        /// Makes the files that are not there yet; returns every file named, up to the first that
        /// failed, and that failure.
        ///
        /// An existing file is simply opened.
        func makeFiles(_ cancellation: CancellationFlag) -> (urls: [URL], failure: (String, any Error)?) {
            let names: [String]
            do {
                names = try self.names(quotedLists: true, cancellation)
            } catch {
                return ([], (typed, error))
            }
            var urls: [URL] = []
            for name in names {
                let url = fileSystems.location(from: name, relativeTo: directory)
                do {
                    if !exists(url, cancellation) {
                        if cancellation.isCancelled {
                            return (urls, nil)
                        }
                        try makeFile(at: url, cancellation)
                    }
                    urls.append(url)
                } catch {
                    if cancellation.isCancelled {
                        return (urls, nil)
                    }
                    let status = OperationRecord.Status.failed(error.localizedDescription)
                    record?(OperationRecord(.newFile, source: fileSystems.displayPath(url), status: status))
                    return (urls, (name, error))
                }
            }
            return (urls, nil)
        }

        /// Makes one empty file, and the folders it is to lie in.
        private func makeFile(at url: URL, _ cancellation: CancellationFlag) throws {
            let provider = try fileSystems.provider(for: url)
            try provider.createDirectory(at: url.deletingLastPathComponent(), cancellation: cancellation)
            try provider.write(url, cancellation: cancellation).close(attributes: FileAttributes())
            record?(OperationRecord(.newFile, source: fileSystems.displayPath(url)))
        }
    }

    /// What the placeholders of a new name refer to (spec 18 › Rename and new-folder
    /// placeholders): the item under the cursor, the folder, the moment the dialog opened.
    private func nameContext(for panel: any PanelHandle, openedAt: Date) -> NameTemplate.Context {
        let model = panel.model
        var context = NameTemplate.Context()
        if let item = source.model.cursorItem {
            context.cursorName = item.name
            context.cursorIsFolder = item.isFolder
            context.cursorSize = item.size
        }
        context.parentName = model.directory.lastPathComponent
        context.grandparentName = model.directory.deletingLastPathComponent().lastPathComponent
        context.now = openedAt
        return context
    }

    /// The new items `typed` names in the folder of `panel`.
    private func newItems(_ typed: String, in panel: any PanelHandle, openedAt: Date) -> NewItems {
        NewItems(
            typed: typed,
            context: nameContext(for: panel, openedAt: openedAt),
            directory: panel.model.directory,
            fileSystems: fileSystems,
            clipboard: clipboard,
            record: recorder()
        )
    }

    /// F7 and Shift+F7 (spec 07 › New folder). `names` given: no dialog; it is the text of the
    /// dialog or the command's switches (`N="a|b"`).
    internal func makeDirectory(in panel: any PanelHandle, names given: String?) {
        let directory = panel.model.directory
        let openedAt = Date()
        let typed: String
        if let given {
            let switches = CommandSwitches.parse(given)
            typed = given.contains("=") ? (switches["N"] ?? "") : given
        } else {
            // Pre-filled with the name under the cursor, so similar names are easy to type.
            guard
                let text = interaction.prompt(
                    "New folder (directory)",
                    value: source.model.cursorItem?.name ?? "",
                    detail: "a/b/c nests, | separates several. With a leading < placeholders work: "
                        + "<[Y]-[M]-[D] notes, <Copy of [N], <1-10>Part [C], <new[C] (first free name)."
                )
            else { return }
            typed = text
        }
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        let items = newItems(typed, in: panel, openedAt: openedAt)
        kernel.jobs.run(
            title: "New folder:",
            work: { monitor in items.makeFolders(monitor.cancellation) },
            completion: { [kernel] result in
                for (name, error) in result.failures {
                    kernel.interaction.report(
                        error,
                        title: "The folder \(DisplayName.escaped(name)) cannot be created!"
                    )
                }
                // The cursor goes to the last new folder, or to the top of a nested one.
                var focus: URL?
                if let created = result.created, created.isInside(directory) {
                    let top = created.pathComponents.dropFirst(directory.pathComponents.count).first
                    focus = top.map(directory.appendingPathComponent)
                }
                kernel.panels.refresh([directory], focus: focus)
            }
        )
    }

    /// Shift+F4 (spec 10 › New text file): the names follow the rules of new folders; several
    /// names create several files and do not start the editor.
    internal func newTextFile(opensEditor: Bool) {
        let model = source.model
        let directory = model.directory
        let openedAt = Date()
        guard
            let typed = interaction.prompt(
                "New text file:",
                value: model.cursorFile?.name ?? "",
                detail: "| or quotes separate several files; a leading < turns on placeholders and ranges."
            )?
            .trimmingCharacters(in: .whitespaces), !typed.isEmpty
        else { return }
        let items = newItems(typed, in: source, openedAt: openedAt)
        kernel.jobs.run(
            title: "New file:",
            work: { monitor in items.makeFiles(monitor.cancellation) },
            completion: { [kernel] result in
                if let (name, error) = result.failure {
                    kernel.interaction.report(error, title: "The file \(DisplayName.escaped(name)) cannot be created!")
                }
                guard let last = result.urls.last else {
                    return
                }
                kernel.panels.refresh([directory], focus: last)
                // One new file opens in the editor, when a plugin provides one.
                if result.urls.count == 1, result.failure == nil, opensEditor, kernel.commands[.edit] != nil {
                    kernel.commands.perform(.edit, .location(last))
                }
            }
        )
    }
}
