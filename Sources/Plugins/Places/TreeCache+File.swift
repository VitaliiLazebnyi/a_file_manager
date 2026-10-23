import AFMKernel
import Foundation

/// The cache file: its text, written in pieces and read back byte by byte.
extension TreeCache {
    /// The tree written to the file in pieces of about a megabyte, so that a tree of a million
    /// folders is never held again as one text.
    ///
    /// False when it would be more than `fileLimit` (nothing replaces the old file then).
    @discardableResult
    internal static func writePrivately(_ entry: Entry, root: URL, to file: URL) -> Bool {
        let temporary = file.path + ".tmp\(getpid())"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            return true
        }
        var total = 0
        var fits = true
        var wrote = true
        format(entry, root: root) { piece in
            total += piece.utf8.count
            guard total <= fileLimit else {
                fits = false
                return false
            }
            var bytes = piece
            wrote = bytes.withUTF8 { buffer in write(descriptor, UnsafeRawBufferPointer(buffer)) }
            return wrote
        }
        close(descriptor)
        if fits, wrote, rename(temporary, file.path) == 0 {
            return true
        }
        unlink(temporary)
        return fits
    }

    /// Writes all of `buffer` to `descriptor`; false when the system refuses part of it.
    private static func write(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer) -> Bool {
        var written = 0
        while written < buffer.count {
            let count = Darwin.write(descriptor, buffer.baseAddress?.advanced(by: written), buffer.count - written)
            if count <= 0 {
                return false
            }
            written += count
        }
        return true
    }

    /// The file's text for a complete tree of `paths` below `root`.
    internal static func format(_ paths: [String], root: URL) -> String {
        format(Entry(paths: paths), root: root)
    }

    /// The file's text for `entry`, all in one string.
    internal static func format(_ entry: Entry, root: URL) -> String {
        var text = ""
        format(entry, root: root) { piece in
            text += piece
            return true
        }
        return text
    }

    /// The file's text in pieces of about a megabyte, for as long as `emit` says to go on.
    internal static func format(_ entry: Entry, root: URL, emit: (String) -> Bool) {
        // A path with a line break would add lines to the file; such a folder is left out, and
        // the tree then is not complete.
        func isPlain(_ path: String) -> Bool { !path.utf8.contains { $0 == 0x0A || $0 == 0x0D } }
        let isComplete = entry.isComplete && entry.paths.allSatisfy(isPlain)
        var piece = "root=\(DirectoryHistory.stored(root))\n"
        if !isComplete {
            piece += "state=partial\n"
        }
        piece.reserveCapacity(1 << 20 + 4_096)
        func line(_ open: String, _ path: String, _ close: String) -> Bool {
            piece += open
            piece += path
            piece += close
            piece += "\n"
            guard piece.utf8.count >= 1 << 20 else {
                return true
            }
            defer { piece.removeAll(keepingCapacity: true) }
            return emit(piece)
        }
        for path in entry.paths where isPlain(path) {
            if !line("[", path, "]") {
                return
            }
        }
        for path in entry.unscanned where isPlain(path) {
            if !line("(", path, ")") {
                return
            }
        }
        if !piece.isEmpty {
            _ = emit(piece)
        }
    }

    /// What a cache file holds; nil when the file is not one for `root`.
    ///
    /// Read byte by byte: the lines end at the line feed byte and are told apart by their
    /// first and last byte, not by characters (a combining mark after `[` makes one
    /// character with it, and a name that began with one would be lost). The text between is
    /// taken from `text` itself, cut where those bytes are.
    internal static func parseEntry(_ text: String, root: URL) -> Entry? {
        let bytes = text.utf8
        var entry = Entry(paths: [])
        var isFirst = true
        // False when the first line is not the header of a file for `root`.
        func take(_ line: Substring.UTF8View) -> Bool {
            guard !line.isEmpty else {
                return true
            }
            guard isFirst else {
                read(line, into: &entry)
                return true
            }
            isFirst = false
            return isHeader(line, of: root)
        }
        // Every line feed ends a line; what follows the last one is a line too (empty when the
        // file ends with a line feed).
        var start = bytes.startIndex
        var index = start
        while true {
            if index == bytes.endIndex || bytes[index] == 0x0A {
                guard take(bytes[start..<index]) else {
                    return nil
                }
                guard index < bytes.endIndex else {
                    break
                }
                start = bytes.index(after: index)
            }
            index = bytes.index(after: index)
        }
        return isFirst ? nil : entry
    }

    /// Whether `line` is the `root=<url>` line of a file for `root`.
    private static func isHeader(_ line: Substring.UTF8View, of root: URL) -> Bool {
        let prefix = "root=".utf8
        guard line.starts(with: prefix) else {
            return false
        }
        let location = String(Substring(line.dropFirst(prefix.count)))
        return URL(string: location)?.locationKey == root.locationKey
    }

    /// Adds what a line after the first says to `entry`: a folder, an unscanned folder or the partial state.
    private static func read(_ line: Substring.UTF8View, into entry: inout Entry) {
        let first = line[line.startIndex]
        let last = line[line.index(before: line.endIndex)]
        if line.count > 2, first == 0x5B, last == 0x5D {
            entry.paths.append(String(Substring(line.dropFirst().dropLast())))
        } else if line.count > 2, first == 0x28, last == 0x29 {
            entry.unscanned.append(String(Substring(line.dropFirst().dropLast())))
        } else if line.elementsEqual("state=partial".utf8) {
            entry.isComplete = false
        }
    }
}
