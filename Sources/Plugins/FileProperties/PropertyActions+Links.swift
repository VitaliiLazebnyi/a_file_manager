import AFMContracts
import AFMKernel
import Foundation

/// Create Link and Show Link Target (spec 07 › Create shortcut).
extension PropertyActions {
    /// What the Create Link dialog asked for.
    private struct LinkRequest {
        /// The target as typed: a folder for the links, or for one link its path.
        let text: String
        /// The folder a relative target counts from.
        let directory: URL
        /// The kind of link.
        let kind: LinkKind
        /// Whether symbolic links get a path relative to their own folder.
        let relative: Bool
    }

    /// What making the links came to, ready for the completion to show.
    private struct LinkResult {
        /// The last link made, for the cursor.
        var created: URL?
        /// Each folder that got a link, once.
        var changed: [URL] = []
        /// How many links could not be made.
        var failed = 0
        /// The first failures: name and reason.
        var failures: [String] = []
    }

    /// Makes the links one after the other until the job is stopped; blocks, on the job's thread.
    nonisolated private static func makeLinks(
        to items: [FileItem],
        as request: LinkRequest,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag
    ) -> LinkResult {
        let location = fileSystems.location(from: request.text, relativeTo: request.directory)
        // A target that ends in a slash, or is a folder, or takes several links, is the
        // folder the links go into under the names of their originals.
        let isFolder =
            request.text.hasSuffix("/") || items.count > 1
            || (try? fileSystems.provider(for: location))?
                .item(
                    at: location,
                    cancellation: cancellation
                )?
                .isDirectory == true
        // What the completion shows is put together here: the first failures only, and
        // each folder that got a link once.
        var result = LinkResult()
        var seen = Set<String>()
        for item in items where !cancellation.isCancelled {
            // A branch view names an item by its path; the link gets the item's own name.
            let destination = isFolder ? location.appending(name: item.url.lastPathComponent) : location
            do {
                try LinkMaker.create(request.kind, to: item.url, at: destination, relative: request.relative)
                result.created = destination
                let folder = destination.deletingLastPathComponent()
                if seen.insert(folder.locationKey).inserted { result.changed.append(folder) }
            } catch {
                result.failed += 1
                if result.failures.count < 20 {
                    result.failures.append("\(PropertyText.shown(item.name)): \(error.localizedDescription)")
                }
            }
        }
        return result
    }

    /// Creates links to the operands, by default in the target panel's folder
    /// (spec 07 › Create shortcut).
    internal func createLinks() {
        let model = source.model
        // The dialog needs how many items there are and, for one, its name; the list of a
        // long selection is made on the job's thread.
        // Offered only where there are operands: the marked ones, or the item under the cursor.
        let operands = model.operandsSnapshot()
        guard let request = askLinks(count: max(operands.markedCount, 1), operands: operands, in: model.directory)
        else { return }
        let registry = fileSystems
        kernel.jobs.run(
            title: "Creating links:",
            work: { monitor in
                Self.makeLinks(
                    to: operands.items(),
                    as: request,
                    fileSystems: registry,
                    cancellation: monitor.cancellation
                )
            },
            completion: { [kernel] result in
                if result.failed > 0 {
                    kernel.interaction.inform(
                        "\(result.failed) link(s) could not be created!",
                        detail: Self.summary(of: result.failures, total: result.failed),
                        style: .warning
                    )
                }
                kernel.panels.refresh(result.changed, focus: result.created)
            }
        )
    }

    /// Goes to where the link under the cursor leads.
    internal func showCursorLinkTarget() {
        _ = source.model.cursorItem.map(showLinkTarget)
    }

    /// Goes to the item the link `item` (under the cursor) leads to, with the cursor on it.
    internal func showLinkTarget(_ item: FileItem) {
        let panel = source
        let directory = panel.model.directory
        kernel.jobs.run(
            title: "Reading link:",
            work: { _ in LocalInfo.resolvedLinkTarget(item.url) },
            completion: { [interaction] target in
                // The answer belongs to the folder it was asked in; elsewhere it would take the panel away.
                guard panel.model.directory.isSameLocation(as: directory) else {
                    return
                }
                guard let target else {
                    return interaction.inform(
                        "\(PropertyText.shown(item.name)) is not a link.",
                        detail: "",
                        style: .information
                    )
                }
                panel.show(target)
            }
        )
    }

    /// Asks where the links go and of which kind; nil when the dialog is cancelled or the target left empty.
    private func askLinks(count: Int, operands: PanelModel.Operands, in directory: URL) -> LinkRequest? {
        let single = count == 1 ? operands.items().first : nil
        let settings = kernel.settings
        let targetPath = fileSystems.displayPath(kernel.panels.target.model.directory)
        let proposal = (targetPath.hasSuffix("/") ? targetPath : targetPath + "/") + (single?.name ?? "")
        let detail = single.map { "Create a link to \"\($0.name)\" as:" } ?? "Create links to \(count) items in:"
        let kinds = LinkKind.allCases
        guard
            let answer = interaction.form(
                "Create link",
                detail: detail,
                fields: [
                    .text("target", "", proposal),
                    .choice(
                        "kind",
                        "Type:",
                        kinds.map(\.title),
                        selected: settings.index(FilePropertiesPlugin.Settings.linkKind, default: 0)
                    ),
                    .checkbox(
                        "relative",
                        "Symbolic link with a relative path",
                        settings.flag(FilePropertiesPlugin.Settings.relativeLinks, default: false)
                    )
                ],
                buttons: ["OK"]
            )
        else { return nil }
        let text = answer.text("target").trimmingCharacters(in: .whitespaces)
        let kind = kinds.indices.contains(answer.index("kind")) ? kinds[answer.index("kind")] : .symbolic
        guard !text.isEmpty else {
            return nil
        }
        return LinkRequest(text: text, directory: directory, kind: kind, relative: answer.flag("relative"))
    }
}
