import Foundation

/// The lines of listings, in the formats of UNIX, Windows and MLSD servers.
extension TestFTPSession {
    /// The kind of listing line `line(for:name:style:)` writes.
    internal enum LineStyle {
        /// `MM-dd-yy  hh:mma  <DIR> name`, as Windows servers send.
        case dos
        /// An MLSD fact line: `type=file;size=…;modify=…;UNIX.mode=…; name`.
        case machine
        /// An `ls -l` line, with `name -> target` for a link.
        case unix
    }

    /// What a listing line tells of an item.
    internal struct Facts {
        /// True for a folder.
        internal let isFolder: Bool
        /// When the item was last changed.
        internal let date: Date
        /// Its size in bytes.
        internal let bytes: Int64
        /// Its permission bits; `0o644` when they cannot be read.
        internal let mode: Int

        /// Reads the facts of the item at `url` with the session's file manager.
        internal init(of url: URL, session: TestFTPSession) {
            isFolder = session.isDirectory(url)
            date = session.modified(url)
            bytes = session.size(of: url)
            let attributes = try? session.fileManager.attributesOfItem(atPath: url.path)
            mode = (attributes?[.posixPermissions] as? Int) ?? 0o644
        }
    }

    /// MDTM and MLSD times: `yyyyMMddHHmmss` in UTC.
    internal static let stampFormat = formatter("yyyyMMddHHmmss", utc: true)
    /// The time of an `ls -l` line for a date of the last half year.
    private static let recentFormat = formatter("MMM dd HH:mm", utc: false)
    /// The year of an `ls -l` line for an older (or future) date.
    private static let oldFormat = formatter("MMM dd  yyyy", utc: false)
    /// The date and time of a DOS line.
    private static let dosFormat = formatter("MM-dd-yy  hh:mma", utc: false)

    /// A date formatter for the POSIX locale, in UTC or in the local time zone.
    private static func formatter(_ format: String, utc: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if utc { formatter.timeZone = TimeZone(identifier: "UTC") }
        return formatter
    }

    /// The size of a file in bytes; 0 when it cannot be read.
    internal func size(of url: URL) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    /// When an item was last changed; now when that cannot be read.
    internal func modified(_ url: URL) -> Date {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? Date()
    }

    /// A date as MDTM and MLSD write it.
    internal func stamp(_ date: Date) -> String { Self.stampFormat.string(from: date) }

    /// The listing line for the item at `url`, under the name `name`.
    internal func line(for url: URL, name: String, style: LineStyle) -> String {
        let facts = Facts(of: url, session: self)
        switch style {
        case .machine:
            let kind = "type=\(facts.isFolder ? "dir" : "file");size=\(facts.bytes);modify=\(stamp(facts.date))"
            return "\(kind);UNIX.mode=0\(String(facts.mode, radix: 8)); \(name)"

        case .dos:
            let sizeColumn = facts.isFolder ? "     <DIR>         " : String(format: "%19lld", facts.bytes)
            return "\(Self.dosFormat.string(from: facts.date))  \(sizeColumn) \(name)"

        case .unix:
            return unixLine(for: url, name: name, facts: facts)
        }
    }

    /// An `ls -l` line; a link shows its target, and its size is the target's length.
    private func unixLine(for url: URL, name: String, facts: Facts) -> String {
        let letters = (0..<9)
            .map { index -> Character in
                facts.mode & (1 << (8 - index)) != 0 ? Array("rwxrwxrwx")[index] : "-"
            }
        let halfYearAgo = Date().addingTimeInterval(-180 * 86_400)
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            let when = (facts.date < halfYearAgo ? Self.oldFormat : Self.recentFormat).string(from: facts.date)
            let size = String(format: "%10lld", Int64(target.utf8.count))
            return "lrwxrwxrwx   1 owner    group    \(size) \(when) \(name) -> \(target)"
        }
        let isOld = facts.date < halfYearAgo || facts.date > Date().addingTimeInterval(3_600)
        let when = (isOld ? Self.oldFormat : Self.recentFormat).string(from: facts.date)
        let size = String(format: "%10lld", facts.bytes)
        return "\(facts.isFolder ? "d" : "-")\(String(letters))   1 owner    group    \(size) \(when) \(name)"
    }
}
