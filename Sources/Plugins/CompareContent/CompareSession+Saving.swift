import AFMKernel
import Foundation

/// Saving: the edited texts written back through their file systems.
extension CompareSession {
    /// An edited side to be written.
    private struct Pending: Sendable {
        /// Which side it is.
        var side: CompareSide
        /// Where it is saved.
        var url: URL
        /// The text to write.
        var document: TextDocument
        /// The file as it was when loaded; a file that differs now is not overwritten.
        var expected: FileItem?

        /// Encodes the text and replaces the file with it; returns the file as it is now.
        @discardableResult
        func write(through fileSystems: FileSystemRegistry) throws -> FileItem? {
            let data = try document.encodedData(named: url.lastPathComponent)
            return try CompareLoader.replace(url, with: data, fileSystems: fileSystems, expected: expected)
        }
    }

    /// What the save job reports for one file.
    private struct Saved: Sendable {
        /// Which side it is.
        var side: CompareSide
        /// Why it was not saved; nil when it was.
        var error: (any Error)?
        /// The file as it is after saving; what the next save is checked against.
        var item: FileItem?
    }

    /// Writes the changed files back, with nothing to tell back.
    internal func save() {
        save { _ in
            // Failures are reported to the user.
        }
    }

    /// Writes the changed files back through their file systems, as a job; `completion` tells
    /// whether everything is saved, edits made while the job ran included.
    internal func save(completion: @escaping (Bool) -> Void) {
        guard case .text(let left, let right, _, _) = content, hasUnsavedChanges else {
            completion(true)
            return
        }
        let files = pending(left, right)
        // Two edited texts of one file cannot both be written: the second would silently replace the first.
        if files.count == 2, CompareLoader.isSameFile(files[0].url, files[1].url) {
            kernel.interaction.report(
                CompareLoader.SaveError.sameFile(fileSystems.displayPath(files[0].url)),
                title: "Nothing was saved."
            )
            completion(false)
            return
        }
        let generation = editGeneration
        let (interaction, panels) = (kernel.interaction, kernel.panels)
        kernel.jobs.run(
            title: "Save",
            work: { [files, fileSystems] monitor -> [Saved] in
                files.enumerated()
                    .map { index, file in
                        monitor.report(
                            JobProgress(
                                lines: ["Save: " + fileSystems.displayPath(file.url)],
                                itemsDone: index,
                                itemsTotal: files.count
                            )
                        )
                        do {
                            return Saved(side: file.side, error: nil, item: try file.write(through: fileSystems))
                        } catch {
                            return Saved(side: file.side, error: error, item: nil)
                        }
                    }
            },
            completion: { [self] results in
                for saved in results {
                    settle(saved, generation: generation, interaction: interaction)
                }
                panels.refresh(files.map { file in file.url.deletingLastPathComponent() })
                updateStatus()
                onChange()
                completion(results.allSatisfy { saved in saved.error == nil } && !hasUnsavedChanges)
            }
        )
    }

    /// Writes the changed files at once on the calling thread, for the program quitting, where a
    /// job can no longer be waited for.
    ///
    /// Returns whether everything was saved; errors are reported.
    internal func saveNow() -> Bool {
        guard case .text(let left, let right, _, _) = content, hasUnsavedChanges else {
            return true
        }
        var allSaved = true
        for file in pending(left, right) {
            do {
                try file.write(through: fileSystems)
                setModified(file.side, false)
            } catch {
                allSaved = false
                kernel.interaction.report(error, title: "\(fileSystems.displayPath(file.url)) could not be saved.")
            }
        }
        return allSaved
    }

    /// The sides with unsaved edits and a file to save them in, left first.
    private func pending(_ left: TextDocument, _ right: TextDocument) -> [Pending] {
        var files: [Pending] = []
        if modified.left, let leftURL {
            files.append(Pending(side: .left, url: leftURL, document: left, expected: loaded.left))
        }
        if modified.right, let rightURL {
            files.append(Pending(side: .right, url: rightURL, document: right, expected: loaded.right))
        }
        return files
    }

    /// Takes in what the save job did for one file: the error is reported, a saved file becomes what the next save
    /// is checked against.
    private func settle(_ saved: Saved, generation: Int, interaction: any UserInteraction) {
        if let error = saved.error {
            interaction.report(error, title: "\(displayPath(saved.side)) could not be saved.")
            return
        }
        // What was written is now the file on disk, whatever was edited since (a link
        // is saved where it leads, so this is never the link).
        if saved.side == .left {
            loaded.left = saved.item
        } else {
            loaded.right = saved.item
        }
        // Only what was saved is settled: an edit made while the job ran is still unsaved.
        if editGeneration == generation {
            setModified(saved.side, false)
        }
    }

    /// Marks one side as modified or not.
    private func setModified(_ side: CompareSide, _ isModified: Bool) {
        if side == .left {
            modified.left = isModified
        } else {
            modified.right = isModified
        }
    }
}
