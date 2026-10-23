/// The options a command carries after its name, as in `cm_Copy /V1 O2 T="/tmp/" W="*.txt" G`
/// (spec 17 › Commands with parameters): a letter, then a number or `="text"`; a quote inside
/// the text is doubled.
///
/// A letter without a number counts as 1.
public enum CommandSwitches {
    /// The switches in `text`, by letter; the value is the text of a `="..."` or the number (1 when none).
    public static func parse(_ text: String) -> [Character: String] {
        var switches: [Character: String] = [:]
        var characters = ArraySlice(text)
        while let letter = characters.popFirst() {
            guard letter.isLetter else { continue }
            if characters.first == "=" {
                characters.removeFirst()
                var value = ""
                if characters.first == "\"" {
                    characters.removeFirst()
                    while let next = characters.popFirst() {
                        if next == "\"" {
                            guard characters.first == "\"" else { break }
                            characters.removeFirst()
                        }
                        value.append(next)
                    }
                } else {
                    while let next = characters.first, next != " ", next != "/" {
                        value.append(characters.removeFirst())
                    }
                }
                switches[letter] = value
            } else {
                var digits = ""
                while let next = characters.first, next.isNumber { digits.append(characters.removeFirst()) }
                switches[letter] = digits.isEmpty ? "1" : digits
            }
        }
        return switches
    }
}
