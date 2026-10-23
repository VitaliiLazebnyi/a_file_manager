import AFMKernel

/// Reads the rows of a list with subfolders through the file systems.
///
/// Blocks; runs on a job's thread. The subfolders of one folder are read on all cores at once,
/// since on a server each listing is a trip of its own; the rows keep the order of the names.
internal struct ListCollector {
    /// The file systems the subfolders are listed through.
    internal let fileSystems: FileSystemRegistry
    /// Hidden items of the subfolders are listed too.
    internal let showHidden: Bool
    /// The files that are listed; folders always are.
    internal let mask: ListMask
    /// How many levels of subfolders are entered; negative means all (spec: `-1` = unlimited).
    internal let depth: Int
    /// Set when the job is cancelled: no further subfolder is read.
    internal let cancellation: CancellationFlag

    /// The rows of `items` and of what lies below them, sorted by name within each folder, each
    /// folder's contents right after its own row.
    internal func rows(of items: [FileItem]) -> [ListRow] {
        rows(of: items, prefix: "", level: 0)
    }

    private func rows(of items: [FileItem], prefix: String, level: Int) -> [ListRow] {
        let wanted = Sorter.sorted(
            items.filter { $0.isRealDirectory || mask.matches($0.name) },
            numeric: true,
            byName: \.name
        )
        return
            Parallel.map(wanted) { item -> [ListRow] in
                let path = prefix + item.name
                var rows = [ListRow(item, path: path)]
                guard item.isRealDirectory, depth < 0 || level < depth, !cancellation.isCancelled,
                    let children = try? fileSystems.provider(for: item.url)
                        .list(
                            item.url,
                            showHidden: showHidden,
                            cancellation: cancellation
                        ),
                    !cancellation.isCancelled
                else { return rows }
                rows += self.rows(of: children, prefix: path + "/", level: level + 1)
                return rows
            }
            .flatMap(\.self)
    }
}
