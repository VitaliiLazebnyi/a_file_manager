import Foundation

/// One wildcard mask against one name, without regard to case (spec 18 › File masks).
public enum Wildcard {
    /// Whether `name` fits the mask `pattern` (`*`, `?`, `[...]`); `*` and `*.*` fit every name.
    ///
    /// A mask that ends in a dot (`*.`, `name.`) also fits a name without an extension.
    public static func matches(_ pattern: String, _ name: String) -> Bool {
        let (mask, lowerName) = (pattern.lowercased(), name.lowercased())
        if mask == "*.*" || mask == "*" {
            return true
        }
        // `*.` and `name.` match names without an extension.
        if mask.hasSuffix("."), !lowerName.contains(".") {
            return fnmatch(String(mask.dropLast()), lowerName, 0) == 0
        }
        return fnmatch(mask, lowerName, 0) == 0
    }
}
