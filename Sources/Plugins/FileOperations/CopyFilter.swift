/// "Only files of this type" of the Copy and Move dialogs (spec 07 › Only files of this type):
/// `include-masks | exclude-masks`, masks separated by spaces, a name with spaces in double
/// quotes.
///
/// A pattern that ends in a slash names folders; with a leading slash it is anchored to the folder
/// the operation starts in. Both `/` and the Windows `\` are read.
///
///     *.txt *.md              only these types, in subfolders as well
///     *.* | *.bak *.old       everything except these
///     *.* | build/ .git/      skip folders with these names, wherever they are
///     *.* /docs/              files of the base folder, plus its direct subfolder docs
///     *.* docs/**/            folders named docs at any depth, with everything below them
///     … | /                   not the files of the base folder itself
///     … | **/                 do not create folders from which no file was copied
///
/// The related-files form `*.jpg>*.cr2` is not supported. A value type without shared state:
/// safe to use from any thread.
public struct CopyFilter: Equatable, Sendable {
    /// Where the walk through a tree is, as far as the filter cares.
    public struct Position: Equatable, Sendable {
        /// 0 in the folder the operation starts in.
        public var depth: Int
        /// Whether the files of this folder are wanted at all.
        public var admitted: Bool
        /// Whether every folder below is wanted too (`name/**/`).
        public var wholeSubtree: Bool
    }

    private struct FolderPattern: Equatable {
        var name: String
        var anchored: Bool
        var recursive: Bool
    }

    private var includedFiles: [String] = []
    private var excludedFiles: [String] = []
    private var includedFolders: [FolderPattern] = []
    private var excludedFolders: [FolderPattern] = []
    private var excludesBaseFiles = false
    /// `| **/`: a folder is created only when a file arrives in it.
    public private(set) var skipsEmptyFolders = false

    /// True when the filter lets everything through.
    public var isEmpty: Bool {
        includedFolders.isEmpty && excludedFolders.isEmpty && excludedFiles.isEmpty && !excludesBaseFiles
            && !skipsEmptyFolders
            && includedFiles.allSatisfy { $0 == "*" || $0 == "*.*" }
    }

    /// The folder the operation starts in.
    public var base: Position {
        Position(depth: 0, admitted: !excludesBaseFiles, wholeSubtree: false)
    }

    /// The filter written as `text` (the syntax above); an empty text lets everything through.
    public init(_ text: String = "") {
        let halves = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        // Splitting keeps empty parts, so there is always a first.
        for token in Self.tokens(halves[0]) {
            if let folder = Self.folderPattern(token) {
                includedFolders.append(folder)
            } else {
                includedFiles.append(token.lowercased())
            }
        }
        for token in Self.tokens(halves.count > 1 ? halves[1] : "") {
            if token == "/" {
                excludesBaseFiles = true
            } else if token == "**/" {
                skipsEmptyFolders = true
            } else if let folder = Self.folderPattern(token) {
                excludedFolders.append(folder)
            } else {
                excludedFiles.append(token.lowercased())
            }
        }
    }

    /// Splits at spaces; double quotes keep a name with spaces together.
    private static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character == " ", !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character == "\\" ? "/" : character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func folderPattern(_ token: String) -> FolderPattern? {
        guard token.hasSuffix("/"), token != "/", token != "**/" else {
            return nil
        }
        var name = String(token.dropLast())
        let recursive = name.hasSuffix("/**")
        if recursive { name = String(name.dropLast(3)) }
        let anchored = name.hasPrefix("/")
        if anchored { name = String(name.dropFirst()) }
        return name.isEmpty ? nil : FolderPattern(name: name.lowercased(), anchored: anchored, recursive: recursive)
    }

    /// The position inside the subfolder `name` of the folder at `position`; nil when the
    /// filter leaves that folder out completely.
    public func entering(_ name: String, from position: Position) -> Position? {
        func matches(_ pattern: FolderPattern) -> Bool {
            (!pattern.anchored || position.depth == 0) && Wildcard.matches(pattern.name, name)
        }
        if excludedFolders.contains(where: matches) {
            return nil
        }
        let next = position.depth + 1
        if includedFolders.isEmpty {
            return Position(depth: next, admitted: true, wholeSubtree: true)
        }
        if position.wholeSubtree {
            return Position(depth: next, admitted: true, wholeSubtree: true)
        }
        if let pattern = includedFolders.first(where: matches) {
            return Position(depth: next, admitted: true, wholeSubtree: pattern.recursive)
        }
        // A folder that is not wanted itself may still hold wanted folders further down.
        return includedFolders.contains { !$0.anchored }
            ? Position(depth: next, admitted: false, wholeSubtree: false) : nil
    }

    /// Whether a file called `name` in the folder at `position` is wanted.
    public func admitsFile(_ name: String, at position: Position) -> Bool {
        guard position.admitted else {
            return false
        }
        if excludedFiles.contains(where: { Wildcard.matches($0, name) }) {
            return false
        }
        return includedFiles.isEmpty || includedFiles.contains { Wildcard.matches($0, name) }
    }
}
