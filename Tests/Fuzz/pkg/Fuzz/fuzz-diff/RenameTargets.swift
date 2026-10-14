import Foundation
import FuzzCore

@testable import MultiRenamePlugin

// MARK: rename mask / rules

/// The longest rename so far (seconds), for the note of the slowest input.
@MainActor internal var slowestRename = 0.0

/// Mask tokens, for the dictionaries of the rename and name template targets.
internal let kMaskDict = [
    "[N]", "[E]", "[A]", "[P]", "[G]", "[S]", "[C]", "[C10+5:3]", "[C+1/100]", "[Caa+1]", "[CZZ-3]", "[C:a]", "[c]",
    "[c2]", "[c3]", "[YMD]", "[hms]",
    "[d]", "[t]", "[i1]", "[v]", "[T1]", "[T2+999999999Y]", "[T3-999999999M]", "[T4]", "[T1+5D]", "[U]", "[L]", "[F]",
    "[f]", "[n]", "[u]", "[I]", "[I1]",
    "[X]", "[X+]", "[%HOME%]", "[%X%\\]", "[%X%_]", "[%HOME%2-5]", "[B1]", "[B+2_1-3]", "[N2-5]", "[N2,3]", "[N-8-5]",
    "[N02-9]", "[N 1,999999999]",
    "[-999999999-999999999]", "[N999999999-]", "[[]", "[]]", "[", "]", "[=tc.size]", "999999999", "-", ",", ":", "+",
    "/", ".", "\u{301}", "ǆ", "ß", "İ", "ﬁ", "🇩🇪"
]

/// The new name of one item, timed; a name that comes out has no control characters and is tidy.
@MainActor
internal func checkNewName(_ item: RenameCase) -> RenameEngine {
    let (settings, subject) = (item.settings, item.subject)
    let started = Date()
    let engine = RenameEngine(settings, context: item.context)
    let name = engine.newName(for: subject, index: item.index, given: item.given)
    _ = engine.newName(for: subject, index: 0)
    let elapsed = Date().timeIntervalSince(started)
    if elapsed > slowestRename, elapsed > 0.005 {
        slowestRename = elapsed
        fzNote(
            "rename slowest \(Int(elapsed * 1_000)) ms search=\(settings.search.debugDescription.prefix(160))"
                + " name=\(subject.name.debugDescription.prefix(120))"
                + " mask=\(settings.nameMask.debugDescription.prefix(120))"
        )
    }
    if let name {
        _ = RenameEngine.invalidity(of: name)
        fzCheck(
            !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 },
            "rename-control-character-left",
            name.debugDescription
        )
        fzCheck(RenameEngine.tidied(name) == name, "rename-tidy-unstable", name.debugDescription)
    }
    return engine
}

/// The rename engine on one item, then its masks, letter cases and search patterns on their own.
@MainActor
internal func runRename(_ bytes: [UInt8], regex: Bool) {
    var choices = Choices(bytes)
    let item = RenameCase(&choices, regex: regex)
    let (settings, subject, index) = (item.settings, item.subject, item.index)
    let engine = checkNewName(item)
    // the masks on their own, with the state carried from name to extension
    let formats = RenameFormats(locale: kPosixLocale, timeZone: kUTC)
    var state = MaskState()
    for maskText in [settings.nameMask, settings.extensionMask, settings.search] {
        let mask = RenameMask(maskText)
        _ = mask.error
        _ = try? mask.evaluate(subject, index: index, context: engine.context, formats: formats, state: &state)
        for case .text(_, let range?) in mask.tokens {
            _ = range.apply(to: subject.name)
            _ = range.apply(to: "")
        }
    }
    for letterCase in LetterCase.allCases {
        _ = letterCase.apply(to: subject.name, rule: item.context.titleRule)
        _ = letterCase.apply(to: settings.replacement)
    }
    let letters = String(settings.replacement.prefix(40).filter { $0.isASCII && $0.isLetter })
    _ = try? RenameMask.alphabetic(letters, advancedBy: index)
    _ = SearchReplace.wildcardPattern(settings.search)
    _ = SearchReplace.systemPattern(settings.search)
}

/// The seeds of `renamemask`.
@MainActor
internal func renameMaskSeeds() -> [[UInt8]] {
    seedsOf([
        "00000000000000[N]\n[E]\n\n\nreport 2024.final.txt\n/Users/me/Docs\nclip\nx:a,b\n",
        "\u{43}\u{1}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}\u{9}"
            + "[N2-5][C10+5:3] [YMD][hms][T2+1D][d] [t]\n[U][E][Caa+1]\n a|*x|?\n_|y\n.hidden file.TAR.gz\n"
            + "/a/b/c/d\nclip\n\n",
        "\u{ff}\u{ff}\u{3}\u{3}\u{4}\u{2}\u{2}\u{1}\u{2}\u{2}\u{3}\u{9}\u{9}\u{9}"
            + "[f][A][c3][c2][C][B+1_2,3][%X%_][X+][I][T4][v]\n[N-8-5][[][]][G][P][S]\nA\nb\n"
            + "the lord of the rings.Mkv\n/x/y\n\nEnglish!:a,the,of\ngiven.name.ext\n"
    ])
}

/// The seeds of `renameregex`.
@MainActor
internal func renameRegexSeeds() -> [[UInt8]] {
    seedsOf([
        "00000000000000[N]\n[E]\n(\\w+) (\\d+)\n\\U$2_\\L$1 $12\nReport 2024.txt\n/d\n\n\n",
        "8000000000000 [N]\n[E]\n(?P<a>x)(?P=a)|^??b|(?'q'c)(?g)\n$1$2$3\\x\\\nxxbc.c\n/d\n\n\n",
        "00000000000000[N]\n[E]\n(a*)*b|()\n<$1>\naaaaaaaaaaaaaaaa.a\n/d\n\n\n"
    ])
}

/// The `renamemask` target: masks and a plain (or wildcard) search.
@MainActor
internal func renameMaskTarget() -> FuzzTarget {
    FuzzTarget(
        "renamemask",
        maxLen: 4_096,
        dict: kMaskDict + ["*", "?", "|", "a|b", "*.*"],
        seeds: renameMaskSeeds,
        run: runRenameMask
    )
}

/// One `renamemask` input.
@MainActor
internal func runRenameMask(_ bytes: [UInt8]) {
    runRename(bytes, regex: false)
}

/// The `renameregex` target: masks and a regular expression search.
@MainActor
internal func renameRegexTarget() -> FuzzTarget {
    FuzzTarget(
        "renameregex",
        maxLen: 2_048,
        dict: kMaskDict.prefix(12) + [
            "(?P<n>", "(?P=n)", "(?'n'", "(?g)", "(?-g)", "^??", "$1", "$12", "\\U$1", "\\L$2", "\\F$1", "\\n$1",
            "$89", "(a+)+$", "(.*)*", "(?=", "(?<=", "\\b", "(", ")", "|", "*?", "{1,3}", "[a-z]", "\\d+", "$", "^",
            "\\", "(?R)", "(?1)", "\\K"
        ],
        seeds: renameRegexSeeds,
        run: runRenameRegex
    )
}

/// One `renameregex` input.
@MainActor
internal func runRenameRegex(_ bytes: [UInt8]) {
    runRename(bytes, regex: true)
}
