import Foundation

/// A parsed rename mask (spec 18 › Rename and new-folder placeholders).
///
/// Parsing never fails: what cannot be read becomes an `invalid` token, and the mask then gives
/// `<Error!>` for every item.
internal struct RenameMask {
    /// Where the text of a text placeholder comes from.
    internal enum Source: Equatable {
        /// `[X]`, `[X+]`: the first line of the clipboard; with `optional`, nothing when it is empty.
        case clipboard(optional: Bool)
        /// `[%NAME%]`: an environment variable, in a form.
        case environment(String, EnvironmentForm)
        /// `[E]`: the extension.
        case ext
        /// `[B+n]`: the n-th folder from the top.
        case folderFromLeft(Int)
        /// `[Bn]`: the n-th folder above the item (`[B0]` is the parent).
        case folderFromRight(Int)
        /// A range without a letter: the full path.
        case fullPath
        /// `[G]`: the folder above the parent.
        case grandparent
        /// `[N]`: the name without the extension.
        case name
        /// `[A]`: the name with the extension.
        case nameWithExt
        /// `[P]`: the parent folder.
        case parent
    }

    /// How an environment variable is written into a name.
    internal enum EnvironmentForm: Equatable {
        /// `[%VAR%\]`: only the last part of a path.
        case lastPart
        /// `[%VAR%_]`: path separators become this character, colons are dropped.
        case separator(Character)
        /// As it is.
        case whole
    }

    /// A date or time field, by its letter in the mask.
    internal enum DateField: Character {
        /// `[i]`: am or pm.
        case amPm = "i"
        /// `[i1]`: a or p.
        case amPmShort = "I"
        /// `[d]`: the short date of the locale.
        case date = "d"
        /// `[D]`: the day, two digits.
        case day = "D"
        /// `[H]`: the hour of the 12-hour clock, two digits.
        case hour12 = "H"
        /// `[h]`: the hour of the 24-hour clock, two digits.
        case hour24 = "h"
        /// `[v]`: the milliseconds, three digits.
        case millisecond = "v"
        /// `[m]`: the minute, two digits.
        case minute = "m"
        /// `[M]`: the month, two digits.
        case month = "M"
        /// `[s]`: the second, two digits.
        case second = "s"
        /// `[t]`: the medium time of the locale.
        case time = "t"
        /// `[y]`: the year, two digits.
        case year2 = "y"
        /// `[Y]`: the year, four digits.
        case year4 = "Y"
    }

    /// `[T1+5h]`: what the time source is moved by.
    internal struct TimeOffset: Equatable {
        /// How many units; negative is earlier.
        internal var value: Int
        /// The unit.
        internal var unit: Calendar.Component
    }

    /// What the `[I]` placeholders do to the folder-dot switch.
    internal enum FolderDot: Equatable {
        /// `[I0]`: the switch is cleared; the dot of a folder's name starts an extension again.
        case clear
        /// `[I1]`: the switch is set; a folder's name has no extension.
        case set
        /// `[I]`: the switch is turned the other way.
        case toggle
    }

    /// One piece of a parsed mask.
    internal enum Token: Equatable {
        /// `[c]`, `[c2]`, `[c3]`.
        case count(Int)
        /// `[C…]`: the counter, the Define-counter one when nil.
        case counter(InlineCounter?)
        /// A date or time field of the time source.
        case date(DateField)
        /// `[I]`, `[I1]` and `[I0]`: the folder-dot switch.
        case folderDot(FolderDot)
        /// A placeholder that cannot be used: the mask gives no name.
        case invalid(RenameMaskError)
        /// `[U]`, `[L]`, `[F]`, `[f]`, `[n]`: the case of what follows.
        case letterCase(LetterCase)
        /// Text outside the brackets.
        case literal(String)
        /// `[u]`: the result is precomposed.
        case precompose
        /// `[S]`: the size in bytes.
        case size
        /// A text placeholder, maybe of a range of its characters.
        case text(Source, CharacterRange?)
        /// `[T1]` to `[T4]`: the time source from here on, maybe moved.
        case timeSource(Int, TimeOffset?)
    }

    /// The pieces of the mask, in order.
    internal let tokens: [Token]

    /// The first thing that is wrong with the mask, for a hint next to the field.
    internal var error: RenameMaskError? {
        for case .invalid(let error) in tokens {
            return error
        }
        return nil
    }

    /// The mask `text`, parsed.
    internal init(_ text: String) {
        var parsed: [Token] = []
        var literal = ""
        let characters = Array(text)
        var position = 0
        func flush() {
            if !literal.isEmpty {
                parsed.append(.literal(literal))
            }
            literal = ""
        }
        while position < characters.count {
            let character = characters[position]
            guard character == "[" else {
                literal.append(character)
                position += 1
                continue
            }
            // `[[]` and `[]]` are the brackets themselves.
            if position + 2 < characters.count, characters[position + 2] == "]",
                characters[position + 1] == "[" || characters[position + 1] == "]"
            {
                literal.append(characters[position + 1])
                position += 3
                continue
            }
            flush()
            guard let close = characters[position...].firstIndex(of: "]") else {
                parsed.append(.invalid(.invalidPlaceholder(String(characters[position...]))))
                break
            }
            parsed += Self.commands(Array(characters[(position + 1)..<close]))
            position = close + 1
        }
        flush()
        tokens = parsed
    }
}
