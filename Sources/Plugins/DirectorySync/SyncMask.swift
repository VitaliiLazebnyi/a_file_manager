import AFMKernel

/// The wildcard field of Synchronize directories (spec 09 › Filter, 18 › File masks): masks
/// separated by spaces or semicolons, masks to leave out after `|`.
///
/// An excluded mask that ends in `/` names folders: such folders are not entered at all.
public struct SyncMask: Sendable {
    /// The files taken; nil takes every file.
    private let include: FileMask?
    /// The files left out; nil leaves out none.
    private let exclude: FileMask?
    /// The folders not entered; nil enters every folder.
    private let excludedFolders: FileMask?

    /// The masks of the field's text.
    public init(_ text: String) {
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        func tokens(_ part: String) -> [String] {
            part.split { character in character == " " || character == ";" }.map(String.init)
        }
        func mask(_ tokens: [String]) -> FileMask? {
            tokens.isEmpty ? nil : FileMask(tokens.joined(separator: " "))
        }
        let isFolderToken = { (token: String) in token.hasSuffix("/") || token.hasSuffix("\\") }
        let excluded = parts.count > 1 ? tokens(parts[1]) : []
        // (A split that keeps empty parts has one part at least.)
        include = mask(tokens(parts[0]))
        exclude = mask(excluded.filter { token in !isFolderToken(token) })
        excludedFolders = mask(excluded.filter(isFolderToken).map { token in String(token.dropLast()) })
    }

    /// Whether a file of that name takes part; an empty include part takes every file.
    public func matchesFile(_ name: String) -> Bool {
        (include?.matches(name) ?? true) && !(exclude?.matches(name) ?? false)
    }

    /// Whether a folder of that name is left out, and not entered.
    public func excludesFolder(_ name: String) -> Bool {
        excludedFolders?.matches(name) ?? false
    }
}
