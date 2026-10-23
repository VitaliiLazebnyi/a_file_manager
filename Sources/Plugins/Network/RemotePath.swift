public import Foundation

/// Paths on a server: always absolute, with `/` between the names.
public enum RemotePath {
    /// The names of a path, without empty ones, `.` and `..`.
    ///
    /// The path is cut at the bytes of the slash, as the server does: cut at characters, a slash
    /// followed by a combining mark would be one character and not a separator, and `a/<mark>..`
    /// would keep its `..`.
    private static func names(_ path: String) -> [Substring] {
        var names: [Substring] = []
        for piece in path.utf8.split(separator: 0x2F) {
            if piece.elementsEqual([0x2E]) { continue }
            if piece.elementsEqual([0x2E, 0x2E]) {
                _ = names.popLast()
                continue
            }
            names.append(Substring(piece))
        }
        return names
    }

    /// The names joined into an absolute path, each after a slash; empty for no names.
    private static func joined(_ names: some Sequence<Substring>) -> String {
        var path = ""
        for name in names {
            path.append("/")
            path.append(contentsOf: name)
        }
        return path
    }

    /// Makes a path absolute and removes empty names, `.` and `..`.
    ///
    /// In the result every slash is a character of its own, for whoever reads the path as text:
    /// a name that begins with a combining mark (or ends with a character that joins what
    /// follows it) would otherwise melt into the slash next to it, and the path would read as
    /// having other names than it has. Such a name gets U+FFFD between itself and the slash. It
    /// is then not the name that was given, on purpose: nothing may be done to a neighbouring
    /// name by mistake. `hasSeparableNames` tells beforehand, and the file system refuses such paths.
    public static func normalized(_ path: String) -> String {
        // Cut at an ASCII byte, every name is still valid UTF-8.
        let result = joined(names(path))
        if result.isEmpty {
            return "/"
        }
        return result.utf8.allSatisfy { $0 < 0x80 } ? result : separated(result)
    }

    /// Whether two scalars next to each other are two characters.
    private static func areApart(_ first: Unicode.Scalar, _ second: Unicode.Scalar) -> Bool {
        var pair = String.UnicodeScalarView()
        pair.append(first)
        pair.append(second)
        return String(pair).count == 2
    }

    /// `path` with every slash made a character of its own (see `normalized`).
    private static func separated(_ path: String) -> String {
        let scalars = Array(path.unicodeScalars)
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == "/" {
                if index > 0, scalars[index - 1] != "/", !areApart(scalars[index - 1], scalar) {
                    result.append("\u{FFFD}")
                }
                result.append(scalar)
                if index + 1 < scalars.count, scalars[index + 1] != "/", !areApart(scalar, scalars[index + 1]) {
                    result.append("\u{FFFD}")
                }
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// False for a path with a name that would melt into the slash before or after it when the
    /// path is read as text (see `normalized`).
    ///
    /// Such a path is not used: what it names cannot be told apart reliably from its neighbours.
    public static func hasSeparableNames(_ path: String) -> Bool {
        if path.utf8.allSatisfy({ $0 < 0x80 }) {
            return true
        }
        let scalars = Array(path.unicodeScalars)
        for (index, scalar) in scalars.enumerated() where scalar == "/" {
            if index > 0, scalars[index - 1] != "/", !areApart(scalars[index - 1], scalar) {
                return false
            }
            if index + 1 < scalars.count, scalars[index + 1] != "/", !areApart(scalar, scalars[index + 1]) {
                return false
            }
        }
        // The first and the last name have a slash next to them once the path is joined to another.
        if let first = scalars.first, first != "/", !areApart("/", first) {
            return false
        }
        if let last = scalars.last, last != "/", !areApart(last, "/") {
            return false
        }
        return true
    }

    /// The folder that holds `path`, normalized; nil for the root, which has none.
    public static func parent(of path: String) -> String? {
        let names = names(path)
        guard !names.isEmpty else {
            return nil
        }
        let parent = joined(names.dropLast())
        return parent.isEmpty ? "/" : normalized(parent)
    }

    /// The last name of `path`; empty for the root.
    public static func name(of path: String) -> String {
        names(path).last.map(String.init) ?? ""
    }

    /// `name` inside `directory`, normalized (a `name` with slashes or `..` is taken as a path).
    public static func join(_ directory: String, _ name: String) -> String {
        normalized(directory + "/" + name)
    }

    /// The path of a URL as the server knows it.
    public static func of(_ url: URL) -> String {
        normalized(url.path)
    }
}
