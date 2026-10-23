import AFMContracts
import AFMKernel
import Foundation

/// Unpack Specific Files (spec 08 › Unpack).
extension ArchiveCommands {
    /// What Unpack reads from.
    internal enum UnpackRequest: Sendable {
        /// Members of the archive the panel is in, below the folder shown: those `members` names
        /// (by their paths in the archive).
        case inside(ArchiveLocation, members: MemberChoice)
        /// The archives among these files.
        case files([FileItem])
    }

    /// The archives `request` names, opened, and a line for each that could not be.
    ///
    /// Their pending changes are written first. On the job's thread.
    nonisolated private static func sources(
        of request: UnpackRequest,
        in store: ArchiveStore,
        cancellation: CancellationFlag
    ) -> (sources: [Unpacker.Source], unreadable: [String]) {
        var sources: [Unpacker.Source] = []
        var unreadable: [String] = []
        switch request {
        case .inside(let inside, let members):
            do {
                try store.flush(inside.archive, cancellation: cancellation)
                sources.append(
                    Unpacker.Source(
                        archive: try store.archive(at: inside.archive, cancellation: cancellation),
                        base: inside.innerPath,
                        selection: members
                    )
                )
            } catch {
                unreadable.append(error.localizedDescription)
            }

        case .files(let items):
            for item in items where !item.isDirectory {
                do {
                    try store.flush(item.url, cancellation: cancellation)
                    sources.append(
                        Unpacker.Source(archive: try store.archive(at: item.url, cancellation: cancellation))
                    )
                } catch {
                    unreadable.append("\(item.name): \(error.localizedDescription)")
                }
            }
        }
        return (sources, unreadable)
    }

    /// The question Unpack asks on the main thread when a file it unpacks exists already.
    nonisolated private static func conflictQuestion(
        monitor: any JobMonitor,
        interaction: any UserInteraction,
        fileSystems: FileSystemRegistry
    ) -> (_ existing: FileItem, _ entry: ArchiveEntry) -> UnpackConflictChoice {
        { existing, entry in
            let detail =
                "\(fileSystems.displayPath(existing.url))\n\(Format.bytes(existing.size)) bytes, "
                + "\(Format.date(existing.modified))\n\nWith file:\n\(entry.path)\n"
                + "\(Format.bytes(entry.size)) bytes, \(Format.date(entry.modified))"
            // `@Sendable`, so that it may be sent from this thread to the main thread.
            return monitor.ask { @Sendable in
                interaction.pick(
                    "Overwrite:",
                    detail: detail,
                    [
                        ("Overwrite", .overwrite), ("Overwrite all", .overwriteAll), ("Skip", .skip),
                        ("Skip all", .skipAll), ("Cancel", .cancel)
                    ],
                    fallback: UnpackConflictChoice.cancel
                )
            }
        }
    }

    /// Asks where to unpack the marked archives, or the marked members of the archive the panel
    /// is in, then unpacks them in a job.
    internal func unpack() {
        refreshOptions()
        let model = source.model
        // (Whether and how many are marked is asked as such: the set of all marked names is not built.)
        let (directory, marked, items) = (model.directory, model.selectionCount, model.operands())
        let inside = ArchiveURL.location(of: directory)
        guard inside != nil || !items.isEmpty else {
            interaction.inform("No files selected!", detail: "", style: .warning)
            return
        }
        let title = inside == nil ? "Unpack specific files from archive to:" : "Unpack \(max(marked, 1)) file(s) to"
        guard let answer = interaction.form("Unpack files", detail: "", fields: unpackFields(title), buttons: ["OK"])
        else { return }
        var options = UnpackOptions()
        options.mask = answer.text("mask").trimmingCharacters(in: .whitespaces).isEmpty ? "*.*" : answer.text("mask")
        options.keepsPaths = answer.flag("paths")
        options.separateFolders = answer.flag("separate")
        options.overwrites = answer.flag("overwrite")
        // An empty target means the archive's own folder (spec 08 › Fields and options).
        let ownFolder = inside.map { $0.archive.deletingLastPathComponent() } ?? directory
        let text = answer.text("target").trimmingCharacters(in: .whitespaces)
        kernel.userTyped(
            location: text,
            relativeTo: ownFolder,
            proposal: fileSystems.displayPath(target.model.directory)
        )
        let targetURL =
            text.isEmpty ? ownFolder : ArchiveURL.resolved(fileSystems.location(from: text, relativeTo: ownFolder))
        // Inside an archive: the marked entries, or everything below the folder shown.
        let request: UnpackRequest =
            inside.map { location in
                let paths = items.map { ArchiveTree.join(location.innerPath, $0.name) }
                return .inside(location, members: marked == 0 ? .all : .paths(paths))
            } ?? .files(items)
        model.saveSelection()
        runUnpack(request, operands: items, of: model, into: targetURL, options: options)
    }

    /// The fields of the Unpack dialog; `title` names the target field.
    private func unpackFields(_ title: String) -> [FormField] {
        [
            .text("target", title, fileSystems.displayPath(target.model.directory)),
            .text("mask", "Files to unpack:", "*.*"),
            .checkbox(
                "paths",
                "Unpack path names if stored with files",
                settings.flag(ArchiveSettings.unpackPaths, default: true)
            ),
            .checkbox(
                "separate",
                "Unpack each archive to a separate subdir (name of the archive)",
                settings.flag(ArchiveSettings.unpackSeparate, default: false)
            ),
            .checkbox(
                "overwrite",
                "Overwrite existing files",
                settings.flag(ArchiveSettings.unpackOverwrite, default: false)
            )
        ]
    }

    /// Unpacks what `request` names into `targetURL` in a job, then reports problems, unmarks
    /// `operands` in `model` and refreshes the panels.
    private func runUnpack(
        _ request: UnpackRequest,
        operands: [FileItem],
        of model: PanelModel,
        into targetURL: URL,
        options: UnpackOptions
    ) {
        kernel.jobs.run(
            title: "Unpacking:",
            work: { [fileSystems, store, interaction] monitor -> UnpackResult in
                let (sources, unreadable) = Self.sources(of: request, in: store, cancellation: monitor.cancellation)
                let unpacker = Unpacker(
                    fileSystems: fileSystems,
                    monitor: monitor,
                    options: options,
                    whileUnpacking: nil,
                    askConflict: Self.conflictQuestion(
                        monitor: monitor,
                        interaction: interaction,
                        fileSystems: fileSystems
                    )
                )
                var result = unpacker.run(sources, into: targetURL)
                result.problems = unreadable + result.problems
                return result
            },
            completion: { [self] result in
                if !result.problems.isEmpty {
                    interaction.inform(
                        result.unpacked > 0 ? "Some files could not be unpacked!" : "Unpacking failed!",
                        detail: Self.summary(of: result.problems),
                        style: .warning
                    )
                } else if !result.cancelled {
                    model.deselect(operands.map(\.name))
                }
                refreshPanels([targetURL], focus: options.separateFolders ? nil : result.firstTarget)
            }
        )
    }
}
