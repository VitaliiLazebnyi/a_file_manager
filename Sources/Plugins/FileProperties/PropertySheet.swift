import AFMContracts
import AFMKernel
import Foundation

/// Collects what the Properties dialog shows (spec 07 › Properties; the sheet belongs to the
/// system on Windows, so here it is the program's own, with the facts Finder's Info shows).
///
/// **Threading.** Everything blocks on the file system and runs on a job's thread; a folder's
/// contents are counted on all cores by `SpaceCalculator`.
internal struct PropertySheet {
    /// The providers that describe the items and their volumes.
    internal let fileSystems: FileSystemRegistry
    /// Where the comments of the items are read.
    internal let comments: CommentStore
    /// Stops the counting of a folder's contents; the sheet then says the figures are incomplete.
    internal var cancellation = CancellationFlag()
    /// Told how far the counting of a folder's contents is; nil reports nothing.
    internal var meter: ProgressMeter?

    private var calculator: SpaceCalculator {
        SpaceCalculator(fileSystems: fileSystems, cancellation: cancellation, meter: meter)
    }

    /// "12 file(s), 3 folder(s)".
    private static func contents(_ totals: SpaceTotals) -> String {
        "\(Format.bytes(Int64(totals.files))) file(s), \(Format.bytes(Int64(totals.folders))) folder(s)"
    }

    /// Owner, group, the flags that are set, and the number of hard links of a file that has several.
    private static func ownershipRows(_ details: LocalDetails, isDirectory: Bool) -> [PropertyRow] {
        var rows = [
            PropertyRow("Owner", "\(LocalInfo.userName(details.ownerID)) (\(details.ownerID))"),
            PropertyRow("Group", "\(LocalInfo.groupName(details.groupID)) (\(details.groupID))")
        ]
        let flags = [(details.isHidden, "Hidden"), (details.isLocked, "Locked")].filter(\.0).map(\.1)
        if !flags.isEmpty { rows.append(PropertyRow("Flags", flags.joined(separator: ", "))) }
        if details.linkCount > 1, !isDirectory {
            rows.append(PropertyRow("Hard links", String(details.linkCount)))
        }
        return rows
    }

    /// Where a symbolic link or an alias leads, the tags and the extended attributes.
    private static func linkAndMetadataRows(_ url: URL) -> [PropertyRow] {
        var rows: [PropertyRow] = []
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
        return rows
    }

    /// The lines for one item: name, kind and place, size, dates, permissions, and what the Mac's
    /// own file system adds (owner, flags, links, tags, extended attributes), the volume and the comment.
    internal func rows(for item: FileItem) -> [PropertyRow] {
        let url = item.url
        let details = LocalInfo.details(url)
        var rows = [
            PropertyRow("Name", item.name), PropertyRow("Kind", LocalInfo.kind(of: item)),
            PropertyRow("Where", fileSystems.displayPath(url.deletingLastPathComponent()))
        ]
        rows += sizeRows(for: item, details: details)
        if let details { rows.append(PropertyRow("Created", PropertyText.longDate(details.created))) }
        rows.append(PropertyRow("Modified", PropertyText.longDate(item.modified)))
        if let details { rows.append(PropertyRow("Accessed", PropertyText.longDate(details.accessed))) }
        rows.append(
            PropertyRow(
                "Permissions",
                "\(Format.permissions(item.permissions)) (\(PropertyText.octal(item.permissions)))"
            )
        )
        if let details { rows += Self.ownershipRows(details, isDirectory: item.isDirectory) }
        rows += Self.linkAndMetadataRows(url)
        if let volume = volumeText(for: url) { rows.append(PropertyRow("Volume", volume)) }
        let comment = comments.comment(for: item, cancellation: cancellation)
        if !comment.isEmpty { rows.append(PropertyRow("Comment", comment)) }
        return rows
    }

    /// The summary for several items: what they are and what they add up to.
    internal func rows(forSeveral items: [FileItem]) -> [PropertyRow] {
        let totals = calculator.measure(items).reduce(SpaceTotals(), +)
        let isLocal = items.allSatisfy(\.url.isFileURL)
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
        rows.append(PropertyRow("Contains", Self.contents(totals)))
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

    /// Size and size on disk of a file; of a folder, the sums of everything inside it, measured now.
    private func sizeRows(for item: FileItem, details: LocalDetails?) -> [PropertyRow] {
        guard item.isRealDirectory else {
            var rows = [PropertyRow("Size", PropertyText.size(item.size))]
            if let details { rows.append(PropertyRow("Size on disk", PropertyText.size(details.allocated))) }
            return rows
        }
        let totals = calculator.measure(directory: item.url)
        let note =
            cancellation.isCancelled
            ? " (stopped; incomplete)" : totals.unreadable > 0 ? " (\(totals.unreadable) folder(s) unreadable)" : ""
        var rows = [PropertyRow("Size", PropertyText.size(totals.bytes) + note)]
        if details != nil { rows.append(PropertyRow("Size on disk", PropertyText.size(totals.allocated))) }
        rows.append(PropertyRow("Contains", Self.contents(totals)))
        return rows
    }

    /// The volume's name with its free and total space, or the name alone when those are not known.
    private func volumeText(for url: URL) -> String? {
        guard let volume = (try? fileSystems.provider(for: url))?.volume(of: url, cancellation: cancellation) else {
            return nil
        }
        guard let free = volume.freeBytes, let total = volume.totalBytes else {
            return volume.name
        }
        return "\(volume.name): \(Format.shortSize(free)) of \(Format.shortSize(total)) free"
    }
}
