import AFMContracts
import AFMKernel
import Foundation

/// Which two files the command compares (spec 09 › Opening and choosing the files).
internal enum CompareOperands {
    /// Two selected files of the source panel; or its one selected file with the first selected
    /// file of the target panel, else with the file of the same name there; or, with nothing
    /// selected, the file under the cursor with the file of the same name in the target panel.
    ///
    /// The target panel's cursor is never used. Works on what the panels list.
    @MainActor
    internal static func choose(source: PanelModel, target: PanelModel) -> (left: URL?, right: URL?) {
        func sameName(as file: FileItem) -> URL? {
            guard !target.directory.isSameLocation(as: source.directory), let row = target.row(ofName: file.name),
                let match = target.item(atRow: row), !match.isDirectory, match.name == file.name
            else {
                return nil
            }
            return match.url
        }
        let selected = selectedFiles(source, limit: 2)
        if selected.count >= 2 {
            return (selected[0].url, selected[1].url)
        }
        if let only = selected.first {
            return (only.url, selectedFiles(target, limit: 1).first?.url ?? sameName(as: only))
        }
        guard let cursor = source.cursorItem, !cursor.isDirectory else {
            return (nil, nil)
        }
        return (cursor.url, sameName(as: cursor))
    }

    /// The first `limit` marked files of `model` in list order.
    ///
    /// Nothing marked is known at once, and the walk over the marks (a bit each) stops at the limit, so a selection
    /// of 300,000 does not cost a pass over them.
    @MainActor
    private static func selectedFiles(_ model: PanelModel, limit: Int) -> [FileItem] {
        guard model.selectionCount > 0 else {
            return []
        }
        let snapshot = model.operandsSnapshot()
        var found: [FileItem] = []
        for index in snapshot.shownItems.indices
        where snapshot.isMarked(at: index) && !snapshot.shownItems[index].isDirectory {
            found.append(snapshot.shownItems[index])
            if found.count == limit {
                break
            }
        }
        return found
    }

    /// The files another plugin named; nil when the argument names none.
    internal static func parse(_ argument: CommandArgument, fileSystems: FileSystemRegistry, base: URL) -> (
        left: URL?, right: URL?
    )? {
        if let location = argument.location {
            return (location, nil)
        }
        guard let text = argument.text else {
            return nil
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
            }
        func location(_ line: String?) -> URL? {
            guard let line, !line.isEmpty else {
                return nil
            }
            if let url = URL(string: line), let scheme = url.scheme, (try? fileSystems.provider(for: url)) != nil,
                scheme.count > 1
            {
                return url
            }
            return fileSystems.location(from: line, relativeTo: base)
        }
        return (location(lines.first), location(lines.count > 1 ? lines[1] : nil))
    }
}
