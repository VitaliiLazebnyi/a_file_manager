import AFMKernel
import Foundation

/// A row of files with an ascending counter in their names (spec 08 › Combine files): a
/// numeric extension (`file.001`), a number inside the name (`name.00000.zip.part`) or the
/// letters of Unix `split` (`fileaa`, `fileab`).
internal enum PartSeries {
    /// Where the counter of a name is, and of which kind.
    private enum Counter {
        /// A run of decimal digits.
        case digits(Range<String.Index>)
        /// The last two letters, a…z each.
        case letters(Range<String.Index>)
    }

    /// The counter of a name; nil when it has none.
    private static func counter(in name: String) -> Counter? {
        func isDigit(_ character: Character) -> Bool { character.isASCII && character.isNumber }
        // An extension of digits is the counter; otherwise the last run of digits in front of
        // the extension is (the digits of `.b64` or `.mp3` count nothing).
        let dot = name.lastIndex(of: ".")
        let numericExtension =
            dot.map { found in
                name.index(after: found) < name.endIndex && name[name.index(after: found)...].allSatisfy(isDigit)
            }
            ?? false
        let searched = numericExtension ? Substring(name) : name[..<(dot ?? name.endIndex)]
        if let last = searched.lastIndex(where: isDigit) {
            var first = last
            while first > name.startIndex, case let before = name.index(before: first), isDigit(name[before]) {
                first = before
            }
            return .digits(first..<name.index(after: last))
        }
        // A name without digits and without an extension counts in its last two letters.
        guard dot == nil, name.count >= 2 else {
            return nil
        }
        let start = name.index(name.endIndex, offsetBy: -2)
        return name[start...].allSatisfy { letter in letter.isASCII && letter.isLowercase }
            ? .letters(start..<name.endIndex) : nil
    }

    /// The name after `name` in its row: the decimal number of the same width, or the
    /// letters a…z with carry (`az` → `ba`).
    ///
    /// Nil when the name has no counter or it is at its end.
    internal static func next(after name: String) -> String? {
        switch counter(in: name) {
        case .digits(let range):
            let digits = name[range]
            guard digits.count <= 18, let value = Int(digits) else {
                return nil
            }
            let next = String(value + 1)
            guard next.count <= digits.count else {
                return nil
            }
            return name.replacingCharacters(
                in: range,
                with: String(repeating: "0", count: digits.count - next.count) + next
            )

        case .letters(let range):
            var letters = Array(name[range].utf8)
            var index = letters.count - 1
            while index >= 0 {
                if letters[index] < UInt8(ascii: "z") {
                    letters[index] += 1
                    // Lower-case ASCII letters only: nothing needs repairing.
                    return name.replacingCharacters(in: range, with: String(repairingUTF8: letters))
                }
                letters[index] = UInt8(ascii: "a")
                index -= 1
            }
            return nil

        case nil:
            return nil
        }
    }

    /// The name of the whole when no `.crc` file tells it: the part's name without its counter.
    internal static func combinedName(forPart name: String) -> String {
        guard let counter = counter(in: name) else {
            return name
        }
        var range: Range<String.Index>
        switch counter {
        case .digits(let found), .letters(let found):
            range = found
        }
        // The dot in front of the counter goes with it: `file.001` → `file`.
        if range.lowerBound > name.startIndex, name[name.index(before: range.lowerBound)] == "." {
            range = name.index(before: range.lowerBound)..<range.upperBound
        }
        let result = name.replacingCharacters(in: range, with: "")
        return result.isEmpty ? name + ".combined" : result
    }

    /// `first` and the files that follow it in its folder, until a name is missing.
    internal static func parts(
        startingAt first: FileItem,
        provider: any FileSystemProvider,
        cancellation: CancellationFlag
    ) -> [FileItem] {
        var parts = [first]
        let directory = first.url.deletingLastPathComponent()
        var name = first.name
        while let next = next(after: name),
            let item = provider.item(at: directory.appending(name: next), cancellation: cancellation), !item.isDirectory
        {
            parts.append(item)
            name = next
        }
        return parts
    }
}
