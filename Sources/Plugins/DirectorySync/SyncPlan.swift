import AFMContracts
import AFMKernel
public import Foundation

/// What Synchronize is about to do, worked out from the rows and their actions
/// (spec 09 › The "Synchronize" dialog and the run).
///
/// A value without behaviour: the dialog shows its counts, the executor carries it out.
public struct SyncPlan: Equatable, Sendable {
    /// A file or folder to copy from one side to the other.
    public struct Copy: Equatable, Sendable {
        /// What is copied.
        public let source: URL
        /// Where the copy goes.
        public var target: URL
        /// The path below the start directories, for sending the copy to another folder.
        public let relativePath: String
        /// Whether it is a folder, which is created rather than copied.
        public let isDirectory: Bool
        /// The size of the file; 0 for a folder.
        public let size: Int64
        /// The source's modification date.
        public let modified: Date
        /// The date the copy is to carry: the source's, moved by the time difference of the two
        /// sides (`SyncOptions.timeOffsetHours`) so that the pair compares equal next time.
        public let targetModified: Date
        /// The source's permissions, which the copy gets.
        public let permissions: UInt16
    }

    /// A file or folder to delete.
    public struct Deletion: Equatable, Sendable {
        /// What is deleted.
        public let url: URL
        /// Whether it is a folder, which is deleted only when empty.
        public let isDirectory: Bool
    }

    /// The copies from the left to the right.
    public var toRight: [Copy] = []
    /// The copies from the right to the left.
    public var toLeft: [Copy] = []
    /// What is deleted on the left.
    public var deleteLeft: [Deletion] = []
    /// What is deleted on the right.
    public var deleteRight: [Deletion] = []

    /// Whether there is nothing to do.
    public var isEmpty: Bool { toRight.isEmpty && toLeft.isEmpty && deleteLeft.isEmpty && deleteRight.isEmpty }

    /// Plans the given rows; the caller passes the visible ones, because only those are
    /// processed (spec 09 › Window and workflow). `timeOffsetHours` is the time difference that
    /// the comparison allowed for (the dates of the right side plus this are the left's).
    public init(rows: [SyncRow], timeOffsetHours: Int = 0) {
        let offset = Double(timeOffsetHours) * 3_600
        for row in rows where row.accepts(row.action) {
            add(row, offset: offset)
        }
    }

    /// `Copy 16 files, total size: 6,363,930 bytes`.
    public static func describe(_ copies: [Copy]) -> String {
        let files = copies.filter { copy in !copy.isDirectory }
        let folders = copies.count - files.count
        let bytes = files.reduce(Int64(0)) { total, copy in total.addingSaturated(copy.size) }
        return "Copy \(files.count) files, total size: \(Format.bytes(bytes)) bytes"
            + (folders > 0 ? ", create \(folders) directories" : "")
    }

    /// The copy of a row's item to `target`, dated `shift` seconds from the item's date.
    private static func copy(of row: SyncRow, _ item: FileItem, to target: URL, shift: Double) -> Copy {
        Copy(
            source: item.url,
            target: target,
            relativePath: row.relativePath,
            isDirectory: row.isDirectory,
            size: row.isDirectory ? 0 : item.size,
            modified: item.modified,
            targetModified: item.modified.addingTimeInterval(shift),
            permissions: item.permissions
        )
    }

    /// Adds what the row's action does.
    private mutating func add(_ row: SyncRow, offset: Double) {
        func delete(_ item: FileItem?, into list: inout [Deletion]) {
            if let item {
                list.append(Deletion(url: item.url, isDirectory: row.isDirectory))
            }
        }
        switch row.action {
        case .nothing:
            break

        // Left plus nothing is right plus the offset: a copy to the right is dated back, one to the left forward.
        case .copyToRight:
            if let left = row.left {
                toRight.append(Self.copy(of: row, left, to: row.rightURL, shift: -offset))
            }

        case .copyToLeft:
            if let right = row.right {
                toLeft.append(Self.copy(of: row, right, to: row.leftURL, shift: offset))
            }

        case .deleteLeft:
            delete(row.left, into: &deleteLeft)

        case .deleteRight:
            delete(row.right, into: &deleteRight)

        case .deleteBoth:
            delete(row.left, into: &deleteLeft)
            delete(row.right, into: &deleteRight)
        }
    }

    /// Sends the copies of one direction to another folder, keeping their relative paths.
    public mutating func retarget(toRight: Bool, root: URL) {
        func moved(_ copies: [Copy]) -> [Copy] {
            // The path is cut at its `/` bytes and nowhere else (`PathSafety`); a copy whose
            // path is not made of plain names (none is, as the comparison makes them) has no
            // place below the new folder and is left out.
            copies.compactMap { copy in
                let names = PathSafety.components(ofRelativePath: copy.relativePath)
                guard !names.isEmpty else {
                    return nil
                }
                var sent = copy
                sent.target = names.reduce(root) { folder, name in folder.appending(name: name) }
                return sent
            }
        }
        if toRight {
            self.toRight = moved(self.toRight)
        } else {
            self.toLeft = moved(self.toLeft)
        }
    }
}
