/// Target masks of Copy and Move (spec 07 › Wildcard target names).
public enum TargetMask {
    /// The name `sourceName` gets under the target mask `mask`: `*` stands for the source's name or
    /// extension, `?` for one of its characters; an empty mask, `*` and `*.*` keep the name.
    public static func apply(_ mask: String, to sourceName: String) -> String {
        if mask.isEmpty || mask == "*.*" || mask == "*" {
            return sourceName
        }
        let source = splitAtLastDot(sourceName)
        let parts = splitAtLastDot(mask)
        let name = expand(source.name, mask: parts.name)
        guard let extMask = parts.ext else {
            return name
        }
        let ext = expand(source.ext ?? "", mask: extMask)
        return ext.isEmpty ? name : name + "." + ext
    }

    /// A name split at its last dot; a name that starts with its only dot has no extension.
    private static func splitAtLastDot(_ text: String) -> (name: String, ext: String?) {
        guard let dot = text.lastIndex(of: "."), dot != text.startIndex else {
            return (text, nil)
        }
        return (String(text[..<dot]), String(text[text.index(after: dot)...]))
    }

    /// One part of a name (the name or the extension) under one part of a mask.
    ///
    /// `?` takes the next character of the source, `*` the rest of it, `**` all of it again, and
    /// `*?` starts over at its beginning; any other character is taken as it is and stands for one
    /// character of the source.
    internal static func expand(_ source: String, mask: String) -> String {
        let characters = Array(source)
        let pattern = Array(mask)
        var out = ""
        var position = 0
        var index = 0
        while index < pattern.count {
            let character = pattern[index]
            let next: Character? = index + 1 < pattern.count ? pattern[index + 1] : nil
            if character == "?" {
                if position < characters.count { out.append(characters[position]) }
                position += 1
                index += 1
            } else if character == "*", next == "*" {
                out += source
                position = characters.count
                index += 2
            } else if character == "*", next == "?" {
                position = 0
                index += 2
            } else if character == "*" {
                if position < characters.count { out += String(characters[position...]) }
                position = characters.count
                index += 1
            } else {
                out.append(character)
                position += 1
                index += 1
            }
        }
        return out
    }
}
