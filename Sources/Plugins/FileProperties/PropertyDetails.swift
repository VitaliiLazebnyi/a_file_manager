import AFMContracts
import AFMKernel
import Foundation

/// The columns this plugin adds to the file list (spec 03 › Custom columns, 15 › Content
/// plugins; the comment column is the Comments view of 03 › View types).
///
/// **Threading.** A column's `value` is called on background threads, several at once. Each
/// value here asks the disk about one item with calls that are safe to make concurrently
/// (`lstat`, `readlink`, `listxattr`, resource values) and keeps no state; the comment column
/// goes through `CommentStore`, which guards its own. Columns that need the Mac's file system
/// are empty for items elsewhere.
enum PropertyColumns {
    static func register(in columns: ColumnRegistry, comments: CommentStore) {
        @Sendable func local(_ item: FileItem, _ text: (LocalDetails) -> String) -> String {
            LocalInfo.details(item.url).map(text) ?? ""
        }
        // The comment file may lie on a server: the reading, and the wait of the other rows
        // for it, end when the panel no longer wants the answer.
        columns.register(
            ContentColumn(
                id: "comment",
                title: "Comment",
                width: 220,
                cancellableValue: { item, cancellation in
                    comments.comment(for: item, cancellation: cancellation).replacingOccurrences(of: "\n", with: " ")
                }
            )
        )
        columns.register(
            ContentColumn(id: "owner", title: "Owner", width: 90) { item in
                local(item) { LocalInfo.userName($0.ownerID) }
            }
        )
        columns.register(
            ContentColumn(id: "group", title: "Group", width: 90) { item in
                local(item) { LocalInfo.groupName($0.groupID) }
            }
        )
        columns.register(
            ContentColumn(id: "created", title: "Created", width: 120) { item in local(item) { Format.date($0.created) }
            }
        )
        columns.register(
            ContentColumn(id: "accessed", title: "Accessed", width: 120) { item in
                local(item) { Format.date($0.accessed) }
            }
        )
        columns.register(
            ContentColumn(id: "octal", title: "Mode", width: 50, alignsRight: true) { item in
                PropertyText.octal(item.permissions)
            }
        )
        columns.register(
            ContentColumn(id: "linkTarget", title: "Link Target", width: 200) { item in
                item.isSymlink ? LocalInfo.linkTarget(item.url) ?? "" : ""
            }
        )
        columns.register(ContentColumn(id: "kind", title: "Kind", width: 140) { item in LocalInfo.kind(of: item) })
        columns.register(
            ContentColumn(id: "tags", title: "Tags", width: 120) { item in
                LocalInfo.tags(item.url).joined(separator: ", ")
            }
        )
        columns.register(
            ContentColumn(id: "xattrCount", title: "Ext. Attributes", width: 60, alignsRight: true) { item in
                let count = LocalInfo.extendedAttributeNames(item.url).count
                return count > 0 ? String(count) : ""
            }
        )
        columns.register(
            ContentColumn(id: "sizeOnDisk", title: "Size on Disk", width: 100, alignsRight: true) { item in
                // A folder's own entry says nothing about its contents; measuring those is a command.
                item.isRealDirectory ? "" : local(item) { Format.bytes($0.allocated) }
            }
        )
    }
}

enum PropertyText {
    /// A name as messages show it: line breaks, direction overrides and characters without
    /// width are written out (`<U+202E>`), so a name cannot make a message say something else.
    static func shown(_ text: String) -> String {
        Format.displayName(text)
    }

    /// `755`; with set-user-ID, set-group-ID or sticky, four digits.
    static func octal(_ mode: UInt16) -> String {
        let text = String(mode & 0o7777, radix: 8)
        return String(repeating: "0", count: max(0, 3 - text.count)) + text
    }

    /// `1,234 bytes (1.21 k)`
    static func size(_ bytes: Int64) -> String {
        "\(Format.bytes(bytes)) bytes" + (bytes >= 1_024 ? " (\(Format.shortSize(bytes)))" : "")
    }

    /// "Sunday, October 11, 2026 at 1:19:22 AM", as a property sheet writes dates.
    static func longDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

/// One line of the Properties dialog.
struct PropertyRow: Equatable {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Collects what the Properties dialog shows (spec 07 › Properties; the sheet belongs to the
/// system on Windows, so here it is the program's own, with the facts Finder's Info shows).
///
/// **Threading.** Everything blocks on the file system and runs on a job's thread; a folder's
/// contents are counted on all cores by `SpaceCalculator`.
struct PropertySheet {
    let fileSystems: FileSystemRegistry
    let comments: CommentStore
    var cancellation = CancellationFlag()
    var meter: ProgressMeter?

    private var calculator: SpaceCalculator {
        SpaceCalculator(fileSystems: fileSystems, cancellation: cancellation, meter: meter)
    }

    func rows(for item: FileItem) -> [PropertyRow] {
        let url = item.url
        let details = LocalInfo.details(url)
        let parent = url.deletingLastPathComponent()
        var rows = [
            PropertyRow("Name", item.name), PropertyRow("Kind", LocalInfo.kind(of: item)),
            PropertyRow("Where", fileSystems.displayPath(parent))
        ]
        if item.isRealDirectory {
            let totals = calculator.measure(directory: url)
            let note =
                cancellation.isCancelled
                ? " (stopped; incomplete)" : totals.unreadable > 0 ? " (\(totals.unreadable) folder(s) unreadable)" : ""
            rows.append(PropertyRow("Size", PropertyText.size(totals.bytes) + note))
            if details != nil { rows.append(PropertyRow("Size on disk", PropertyText.size(totals.allocated))) }
            rows.append(
                PropertyRow(
                    "Contains",
                    "\(Format.bytes(Int64(totals.files))) file(s), \(Format.bytes(Int64(totals.folders))) folder(s)"
                )
            )
        } else {
            rows.append(PropertyRow("Size", PropertyText.size(item.size)))
            if let details { rows.append(PropertyRow("Size on disk", PropertyText.size(details.allocated))) }
        }
        if let details { rows.append(PropertyRow("Created", PropertyText.longDate(details.created))) }
        rows.append(PropertyRow("Modified", PropertyText.longDate(item.modified)))
        if let details { rows.append(PropertyRow("Accessed", PropertyText.longDate(details.accessed))) }
        rows.append(
            PropertyRow(
                "Permissions",
                "\(Format.permissions(item.permissions)) (\(PropertyText.octal(item.permissions)))"
            )
        )
        if let details {
            rows.append(PropertyRow("Owner", "\(LocalInfo.userName(details.ownerID)) (\(details.ownerID))"))
            rows.append(PropertyRow("Group", "\(LocalInfo.groupName(details.groupID)) (\(details.groupID))"))
            let flags = [(details.isHidden, "Hidden"), (details.isLocked, "Locked")].filter(\.0).map(\.1)
            if !flags.isEmpty { rows.append(PropertyRow("Flags", flags.joined(separator: ", "))) }
            if details.linkCount > 1, !item.isDirectory {
                rows.append(PropertyRow("Hard links", String(details.linkCount)))
            }
        }
        if let written = LocalInfo.linkTarget(url) {
            rows.append(PropertyRow("Link target", written))
        } else if let original = LocalInfo.resolvedLinkTarget(url) {
            rows.append(PropertyRow("Alias of", original.path))
        }
        let tags = LocalInfo.tags(url)
        if !tags.isEmpty { rows.append(PropertyRow("Tags", tags.joined(separator: ", "))) }
        let attributes = LocalInfo.extendedAttributeNames(url)
        if !attributes.isEmpty {
            rows.append(
                PropertyRow("Extended attributes", "\(attributes.count): " + attributes.joined(separator: ", "))
            )
        }
        if let volume = volumeText(for: url) { rows.append(PropertyRow("Volume", volume)) }
        let comment = comments.comment(for: item, cancellation: cancellation)
        if !comment.isEmpty { rows.append(PropertyRow("Comment", comment)) }
        return rows
    }

    /// The summary for several items: what they are and what they add up to.
    func rows(forSeveral items: [FileItem]) -> [PropertyRow] {
        let totals = calculator.measure(items).reduce(SpaceTotals(), +)
        let isLocal = items.allSatisfy { $0.url.isFileURL }
        var rows = [
            PropertyRow(
                "Items",
                "\(items.count): " + items.prefix(4).map(\.name).joined(separator: ", ")
                    + (items.count > 4 ? ", …" : "")
            )
        ]
        if let first = items.first {
            rows.append(PropertyRow("Where", fileSystems.displayPath(first.url.deletingLastPathComponent())))
        }
        rows.append(
            PropertyRow(
                "Size",
                PropertyText.size(totals.bytes) + (cancellation.isCancelled ? " (stopped; incomplete)" : "")
            )
        )
        if isLocal { rows.append(PropertyRow("Size on disk", PropertyText.size(totals.allocated))) }
        rows.append(
            PropertyRow(
                "Contains",
                "\(Format.bytes(Int64(totals.files))) file(s), \(Format.bytes(Int64(totals.folders))) folder(s)"
            )
        )
        if let newest = items.map(\.modified).max(), let oldest = items.map(\.modified).min() {
            rows.append(
                PropertyRow(
                    "Modified",
                    oldest == newest
                        ? PropertyText.longDate(newest) : "\(Format.date(oldest)) – \(Format.date(newest))"
                )
            )
        }
        let modes = Set(items.map(\.permissions))
        if modes.count == 1, let mode = modes.first {
            rows.append(PropertyRow("Permissions", "\(Format.permissions(mode)) (\(PropertyText.octal(mode)))"))
        }
        if let first = items.first, let volume = volumeText(for: first.url) {
            rows.append(PropertyRow("Volume", volume))
        }
        return rows
    }

    private func volumeText(for url: URL) -> String? {
        guard let volume = (try? fileSystems.provider(for: url))?.volume(of: url, cancellation: cancellation) else {
            return nil
        }
        guard let free = volume.freeBytes, let total = volume.totalBytes else { return volume.name }
        return "\(volume.name): \(Format.shortSize(free)) of \(Format.shortSize(total)) free"
    }
}

/// The kinds of link Create Link makes (spec 07 › Create shortcut; a `.lnk` shortcut is a
/// symbolic link or a Finder alias on the Mac).
enum LinkKind: Int, CaseIterable {
    case symbolic, alias, hard

    var title: String {
        switch self {
        case .symbolic: return "Symbolic link"
        case .alias: return "Finder alias"
        case .hard: return "Hard link"
        }
    }
}

/// Creates links on the Mac's own file system. Blocks; for a job's thread.
enum LinkMaker {
    /// Creates a link at `destination` that leads to `source`. An existing item at the
    /// destination is never replaced. `relative` writes a symbolic link's target relative to
    /// the link's own folder, so the pair can be moved together.
    static func create(_ kind: LinkKind, to source: URL, at destination: URL, relative: Bool) throws {
        guard source.isFileURL, destination.isFileURL else { throw FileSystemError.notSupported("Creating links") }
        var existing = stat()
        if lstat(destination.path, &existing) == 0 { throw FileSystemError.alreadyExists(destination.path) }
        switch kind {
        case .symbolic:
            let target =
                relative ? relativePath(from: destination.deletingLastPathComponent(), to: source) : source.path
            if symlink(target, destination.path) != 0 { throw LocalInfo.posixError(errno, destination) }

        case .hard:
            if link(source.path, destination.path) != 0 { throw LocalInfo.posixError(errno, destination) }

        case .alias:
            let bookmark = try source.bookmarkData(
                options: .suitableForBookmarkFile,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try URL.writeBookmarkData(bookmark, to: destination)
        }
    }

    /// The path that leads from `directory` to `target`: `../B/file.txt`.
    static func relativePath(from directory: URL, to target: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents
        let to = target.standardizedFileURL.pathComponents
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        let steps = Array(repeating: "..", count: from.count - common) + to[common...]
        return steps.isEmpty ? "." : steps.joined(separator: "/")
    }
}
