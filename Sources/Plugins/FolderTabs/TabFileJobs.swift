import AFMContracts
import AFMKernel
import Foundation

/// Tab files read and written through their own file systems, in jobs (spec 03 › Tab files and
/// storage).
///
/// The commands start here on the main thread; the files are touched on the job's thread only.
internal enum TabFileJobs {
    /// Why a tab file cannot be read or written.
    private enum TabFileError: LocalizedError {
        /// The location is a folder or something else that is not a file.
        case notAFile(String)
        /// The file is longer than `FolderTabsPlugin.tabFileLimit`.
        case tooLarge(String)

        /// The message for the user, with the file's path.
        var errorDescription: String? {
            switch self {
            case .notAFile(let path):
                return "\(path) is not a file."

            case .tooLarge(let path):
                return "\(path) is too large to be a tab file."
            }
        }
    }

    /// What a save came to.
    private enum SaveOutcome {
        /// The user kept the file that was there.
        case declined
        /// The file could not be written.
        case failed(any Error)
        /// The file is written.
        case saved
    }

    /// The file a tab-file command works on: its parameter, or what the user enters.
    ///
    /// A name without an extension gets `.tab`. Main thread.
    @MainActor
    internal static func file(for argument: CommandArgument, question: String, kernel: Kernel) -> URL? {
        let directory = kernel.panels.source.model.directory
        if let location = argument.location {
            return location
        }
        guard
            let text = argument.text
                ?? kernel.interaction.prompt(
                    question,
                    value: kernel.fileSystems.displayPath(directory.appending(name: "tabs.tab"))
                ),
            !text.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let file = kernel.fileSystems.location(from: text, relativeTo: directory)
        return file.pathExtension.isEmpty ? file.appendingPathExtension("tab") : file
    }

    /// Writes `contents` to `file` in a job, asking before a file that is there is replaced.
    ///
    /// Main thread; afterwards the folder is read again with the cursor on the file, or the
    /// failure is reported.
    @MainActor
    internal static func save(_ contents: TabFile, to file: URL, kernel: Kernel) {
        let data = Data(contents.text(displayPath: kernel.fileSystems.displayPath).utf8)
        let (registry, interaction) = (kernel.fileSystems, kernel.interaction)
        kernel.jobs.run(
            title: "Save tabs",
            work: { monitor -> SaveOutcome in
                do {
                    return try write(data, to: file, registry: registry) { path in
                        // `@Sendable`, so that it may be sent from this thread to the main thread.
                        monitor.ask { @Sendable in
                            interaction.choose(
                                "Overwrite the tab file?",
                                detail: path,
                                buttons: ["Overwrite", "Cancel"],
                                style: .warning
                            ) == 0
                        }
                    }
                } catch {
                    return .failed(error)
                }
            },
            completion: { outcome in
                switch outcome {
                case .declined:
                    break

                case .failed(let error):
                    kernel.interaction.report(error, title: "The tabs could not be saved.")

                case .saved:
                    kernel.panels.refresh([file.deletingLastPathComponent()], focus: file)
                }
            }
        )
    }

    /// Reads `file` in a job and hands what it holds to `apply` on the main thread.
    ///
    /// Main thread. A failure, or a file that holds no tabs, is reported instead.
    @MainActor
    internal static func load(_ file: URL, kernel: Kernel, then apply: @escaping @MainActor (TabFile) -> Void) {
        let registry = kernel.fileSystems
        let base = kernel.panels.source.model.directory
        kernel.jobs.run(
            title: "Load tabs",
            work: { _ in
                Result { try read(file, relativeTo: base, registry: registry) }
            },
            completion: { result in
                switch result {
                case .failure(let error):
                    kernel.interaction.report(error, title: "The tabs could not be loaded.")

                case .success(let parsed):
                    guard let contents = parsed else {
                        kernel.interaction.inform(
                            "The file holds no tabs.",
                            detail: registry.displayPath(file),
                            style: .warning
                        )
                        return
                    }
                    apply(contents)
                }
            }
        )
    }

    /// Writes the data under another name and renames it when complete: the old file is there
    /// until the new one is, and a failure leaves it as it was.
    ///
    /// On the job's thread. `asking` is asked, with the file's path, whether a file that is there
    /// is replaced; only a file is, a folder or anything else of that name stays (that throws).
    private static func write(
        _ data: Data,
        to file: URL,
        registry: FileSystemRegistry,
        asking overwrite: (String) -> Bool
    ) throws -> SaveOutcome {
        let provider = try registry.provider(for: file)
        let existing = provider.item(at: file)
        if let existing {
            guard !existing.isDirectory, !existing.isSpecial else {
                throw TabFileError.notAFile(registry.displayPath(file))
            }
            guard overwrite(registry.displayPath(file)) else {
                return .declined
            }
        }
        let temporary = file.deletingLastPathComponent().appending(name: ".afm-\(UUID().uuidString).tmp")
        do {
            let writer = try provider.write(temporary)
            try writer.write(data)
            try writer.close(attributes: FileAttributes())
            try provider.move(temporary, to: file, replacing: existing != nil)
        } catch {
            try? provider.remove(temporary)
            throw error
        }
        return .saved
    }

    /// The tabs of a tab file, its paths read from `base`; nil when it holds none.
    ///
    /// On the job's thread: the file may be a megabyte of lines. Throws for a location that is
    /// not a file, a file longer than `FolderTabsPlugin.tabFileLimit`, and what the file system
    /// threw.
    private static func read(_ file: URL, relativeTo base: URL, registry: FileSystemRegistry) throws -> TabFile? {
        let provider = try registry.provider(for: file)
        if let item = provider.item(at: file), item.isDirectory || item.isSpecial {
            throw TabFileError.notAFile(registry.displayPath(file))
        }
        let reader = try provider.read(file)
        defer { reader.close() }
        var data = Data()
        while let block = try reader.read(upToCount: 1 << 16), !block.isEmpty {
            data.append(block)
            // A tab file is a few lines of text; anything long is something else.
            guard data.count <= FolderTabsPlugin.tabFileLimit else {
                throw TabFileError.tooLarge(registry.displayPath(file))
            }
        }
        return TabFile(text: TabFile.text(decoding: data)) { path in registry.location(from: path, relativeTo: base) }
    }
}
