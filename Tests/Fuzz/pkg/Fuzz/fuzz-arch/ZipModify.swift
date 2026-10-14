import AFMKernel
import Foundation
import FuzzCore

@testable import ArchivesPlugin

/// The modify path: add a member, rename one, change a date, write it all into the file.
///
/// Either that throws, or the archive opens again and holds what it held, plus the changes.
@MainActor
internal func runZipModify(_ bytes: [UInt8]) {
    let name = "m.zip"
    let (root, archive) = prepare(bytes, name: name)
    let opened = Opened.open(archive)
    defer { opened.store.close() }
    let before = opened.browse(readLimit: 48 << 20)
    guard before.listed else {
        return
    }
    let added = Data("added by the fuzzer \(bytes.count)\n".utf8)
    let newURL = opened.root.appendingPathComponent("fz-added.txt")
    let changes = change(opened, adding: added, at: newURL, files: before.contents.keys.sorted())
    do {
        try opened.provider.commit(opened.root, cancellation: CancellationFlag())
    } catch {
        checkContainment(root, archiveName: name, what: "modify, commit threw")
        return
    }
    checkContainment(root, archiveName: name, what: "modify")
    guard changes.changed else {
        return
    }
    // A new store reads the file as it now is.
    let again = Opened.open(archive)
    defer { again.store.close() }
    let after = again.browse(readLimit: 48 << 20)
    fzCheck(
        after.listed,
        "zipmod-unreadable-after-commit",
        "the archive no longer opens after a commit that reported success"
    )
    fzCheck(
        after.contents[newURL.path] == added,
        "zipmod-added-member-lost",
        "have \(after.contents.keys.sorted().prefix(20))"
    )
    checkMembersKept(before: before, after: after, changes: changes, addedPath: newURL.path)
}

/// Adds `added` at `newURL`, renames the first of `files` and dates the last; stops at the first
/// change that throws.
private func change(_ opened: Opened, adding added: Data, at newURL: URL, files: [String]) -> ZipChanges {
    var changes = ZipChanges()
    do {
        let writer = try opened.provider.write(newURL)
        try writer.write(added)
        try writer.close(
            attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_600_000_000), permissions: 0o644)
        )
        changes.changed = true
        if let first = files.first {
            let source = opened.url(path: first)
            let destination = source.deletingLastPathComponent().appendingPathComponent("fz-renamed.bin")
            try opened.provider.move(source, to: destination, replacing: false)
            changes.renamed = (first, destination.path)
        }
        if files.count > 1, let last = files.last {
            try opened.provider.setAttributes(
                FileAttributes(modified: Date(timeIntervalSince1970: 1_234_567_890)),
                of: opened.url(path: last)
            )
            changes.dated = last
        }
    } catch {
        // A refused change is allowed; what was changed before it must still be written.
    }
    return changes
}

/// Every member that was there before holds the same bytes after the commit, under its new name
/// if it was renamed.
private func checkMembersKept(before: BrowseResult, after: BrowseResult, changes: ZipChanges, addedPath: String) {
    for (path, data) in before.contents {
        if path == addedPath || changes.isRenameTarget(path) {
            continue
        }
        let now = changes.pathNow(of: path)
        let found = after.contents[now].map { "\($0.count) bytes" } ?? "unreadable"
        fzCheck(
            after.contents[now] == data,
            "zipmod-member-changed",
            "\(path) (now \(now)): \(data.count) bytes before, \(found) after; dated=\(changes.dated ?? "-")"
        )
    }
}
