import AFMKernel
import Foundation

/// `*` and `?` matching as file masks use it (spec 18 › Core syntax).
internal enum Wildcard {
    /// Both sides are expected in lower case. `*.*` matches every name, `name.*` and `name.`
    /// also match `name` without an extension, as they do under DOS.
    internal static func matches(_ pattern: [Character], _ name: [Character]) -> Bool {
        let (whole, wholeName) = (pattern[pattern.indices], name[name.indices])
        if glob(whole, wholeName) {
            return true
        }
        guard !name.contains(".") else {
            return false
        }
        if pattern.count >= 2, pattern.suffix(2) == [".", "*"] {
            return glob(pattern.dropLast(2), wholeName)
        }
        if pattern.last == "." {
            return glob(pattern.dropLast(), wholeName)
        }
        return false
    }

    /// The same for a plain ASCII pattern in lower case and a plain ASCII name (of any case).
    internal static func matches(ascii pattern: [UInt8], _ name: UnsafeBufferPointer<UInt8>) -> Bool {
        if glob(pattern[pattern.indices], name) {
            return true
        }
        guard !name.contains(UInt8(ascii: ".")) else {
            return false
        }
        if pattern.count >= 2, pattern[pattern.count - 2] == UInt8(ascii: "."),
            pattern[pattern.count - 1] == UInt8(ascii: "*")
        {
            return glob(pattern.dropLast(2), name)
        }
        if pattern.last == UInt8(ascii: ".") {
            return glob(pattern.dropLast(), name)
        }
        return false
    }

    /// The two-pointer match of `glob` on bytes; the name's capital ASCII letters count as small ones.
    private static func glob(_ pattern: ArraySlice<UInt8>, _ name: UnsafeBufferPointer<UInt8>) -> Bool {
        func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }
        var (next, letter) = (pattern.startIndex, 0)
        var star: Int?
        var mark = letter
        while letter < name.count {
            if next < pattern.endIndex, pattern[next] == UInt8(ascii: "?") || pattern[next] == lower(name[letter]) {
                next += 1
                letter += 1
            } else if next < pattern.endIndex, pattern[next] == UInt8(ascii: "*") {
                star = next
                mark = letter
                next += 1
            } else if let star {
                next = star + 1
                mark += 1
                letter = mark
            } else {
                return false
            }
        }
        while next < pattern.endIndex, pattern[next] == UInt8(ascii: "*") { next += 1 }
        return next == pattern.endIndex
    }

    /// The usual two-pointer match: linear in practice, without recursion.
    private static func glob(_ pattern: ArraySlice<Character>, _ name: ArraySlice<Character>) -> Bool {
        var (next, letter) = (pattern.startIndex, name.startIndex)
        var star: Int?
        var mark = letter
        while letter < name.endIndex {
            if next < pattern.endIndex, pattern[next] == "?" || pattern[next] == name[letter] {
                next += 1
                letter += 1
            } else if next < pattern.endIndex, pattern[next] == "*" {
                star = next
                mark = letter
                next += 1
            } else if let star {
                next = star + 1
                mark += 1
                letter = mark
            } else {
                return false
            }
        }
        while next < pattern.endIndex, pattern[next] == "*" { next += 1 }
        return next == pattern.endIndex
    }

    /// Applies a rename mask to a name, part by part (name and extension): a letter replaces
    /// the letter at its place, `?` keeps it and `*` keeps the rest. `*.cr2` turns
    /// `IMG_1057.JPG` into `IMG_1057.cr2`, `crw*.cr2` into `crw_1057.cr2`, `*.` into `IMG_1057`.
    internal static func rename(_ name: String, with mask: String) -> String {
        func apply(_ part: String, to text: String) -> String {
            let source = Array(text)
            var result = ""
            var position = 0
            for character in part {
                switch character {
                case "*":
                    if position < source.count { result += String(source[position...]) }
                    position = source.count

                case "?":
                    if position < source.count { result.append(source[position]) }
                    position += 1

                default:
                    result.append(character)
                    position += 1
                }
            }
            return result
        }
        // A mask that ends in a dot gives names without an extension (`*.`).
        let (maskBase, maskExt) = FileItem.split(mask.hasSuffix(".") ? String(mask.dropLast()) : mask)
        let (base, ext) = FileItem.split(name)
        let newExt = apply(maskExt, to: ext)
        return apply(maskBase, to: base) + (newExt.isEmpty ? "" : "." + newExt)
    }
}
