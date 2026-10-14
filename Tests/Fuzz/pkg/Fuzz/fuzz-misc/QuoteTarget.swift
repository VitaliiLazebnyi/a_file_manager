import FuzzCore

// Names and values against real shells.
//
// The contract since review 2: what a placeholder stands for is data. The shell is given the
// user's line with a reference in place of every value (`ShellLine.script`) and the values as
// its arguments, started the way the program starts it (`ChildProcess.spawn`, arguments byte
// for byte). So for every name, in every place a placeholder may stand:
//   1. nothing of the name runs (no file appears in the folder the line ran in, and the output
//      holds exactly the expected arguments);
//   2. the program receives the name byte for byte (only a name that begins with `-` and is a
//      word of its own arrives as `./-name`, the same file);
//   3. the text the shell reads does not depend on the names at all;
//   4. in a place where no reference is safe the line is refused, never run.

/// The `quote` target: hostile names, folders, variable values and marked names in every template.
@MainActor
internal enum QuoteTarget {
    /// The parts hostile names are made of.
    private static let pieces: [String] = [
        " ", "\t", "\n", "\r", "\"", "'", "\\", "$", "`", "!", "*", "?", "[", "]", "(", ")", "{", "}", "<", ">", "|",
        "&", ";", "~", "#", "=", "-", "%", "^", ",", ":", "@", "+", ".", "a", "b", "x", "$(id)", "`id`", "${HOME}",
        "$HOME", "\u{301}", "\u{200D}", "\u{FE0F}", "\u{1F600}", "é", "\u{A0}", "\u{2028}", "\u{85}", "\u{1}",
        "\u{7F}", "\u{1B}", "\u{8}", "\\n", "--", "-n", "-e", "'\\''", "\"\"", "\u{20D2}", "\u{0338}", ".txt", "a.",
        "..", "\u{FEFF}", "\u{3000}", "$0", "$1", "~root", "=ls", "{a,b}", "*.*", "\u{0}",
        // Each of these makes a file named M… in the folder of the run if a shell ever reads it as code.
        "$(touch M1)", "`touch M2`", ";touch M3;", "\ntouch M4\n", "|touch M5", "&&touch M6", ">M7",
        "$(touch M8)\u{301}", "\"\u{301};touch M9;\"\u{301}", "';touch M10;'", "\";touch M11;\"", "\\\u{301}",
        "$\u{301}(touch M12)", "${IFS}touch${IFS}M13", "%Q", "%N", "%|V|", "${__afm_1}", "\"${1}\"", "e\u{301}",
        "\u{1100}\u{1161}", "\u{212B}"
    ]

    /// How many cases this worker checked.
    private static var casesRun = 0

    /// The target.
    internal static func make() -> FuzzTarget {
        FuzzTarget("quote", maxLen: 1_024, seeds: seeds, run: run)
    }

    /// Inputs that pick each kind of part.
    private static func seeds() -> [[UInt8]] {
        [
            [1, 0, 1, 4, 1, 5, 1, 7, 1, 8, 2, 4, 41, 2, 26, 34],
            [3, 34, 0, 34, 2, 5, 0, 37, 2, 4, 37, 1, 61, 2, 34, 41],
            [2, 0xC1, 0x41, 0xC1, 0x80, 1, 0xC1, 0xFF, 1, 3, 2, 26, 26],
            Array(repeating: 4, count: 20), Array(repeating: 41, count: 20), Array(0..<64), Array(64..<128),
            Array((128..<192).map { UInt8($0) }),
            Array((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }),
            Array((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 101 &+ 3) })
        ]
    }

    /// A name of one to six parts: pieces of shell syntax, single bytes as characters, or any scalar.
    internal static func hostileName(_ choices: inout Choices) -> String {
        var name = ""
        let count = 1 + Int(choices.byte() % 6)
        for _ in 0..<count {
            let byte = choices.byte()
            if byte < 0xC0 {
                name += pieces[Int(byte) % pieces.count]
            } else if byte < 0xE0 {
                // Every byte value 0x01–0xFF as a character.
                name.unicodeScalars.append(Unicode.Scalar(UInt8(max(1, choices.byte()))))
            } else if let scalar = Unicode.Scalar(choices.u32() % 0x11_0000), scalar.value != 0 {
                name.unicodeScalars.append(scalar)
            }
        }
        name.unicodeScalars.removeAll { $0 == "/" || $0.value == 0 }
        return name.isEmpty ? "a" : name
    }

    /// Several sets of names per shell launch: launching is what takes the time.
    private static func run(_ bytes: [UInt8]) {
        var choices = Choices(bytes)
        var cases: [QuoteCase] = []
        var sets = 0
        while sets < 12, sets == 0 || !choices.atEnd {
            sets += 1
            let name = hostileName(&choices)
            let dir = hostileName(&choices)
            let value = hostileName(&choices)
            let selection = [hostileName(&choices), hostileName(&choices), hostileName(&choices)]
            cases += QuoteCaseBuilder.cases(name: name, dir: dir, value: value, selection: selection)
        }
        QuoteChecks.check(cases)
        casesRun += cases.count * 2
        fzNote("quote cases checked by this worker: \(casesRun)")
    }
}
